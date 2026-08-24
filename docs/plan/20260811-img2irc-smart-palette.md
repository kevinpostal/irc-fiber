# img2irc Smart Palette Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Add `midgardMode='smart'` that derives two per-image palettes — a truecolor k-means palette (K=24, `\x04`) and a smart mIRC-99 subset (K≈16, `\x03`) — so art color choices are optimal for the image while staying stock-client compatible.

**Architecture:** `smartPalette()` runs once per image in OKLab (k-means for Palette A, frequency-rank + digit-bias subset selection for Palette B), caches the result, and feeds the existing Viterbi. Palette A uses the `\x04` emission already in `renderPixelsCore`; Palette B replaces the per-row `S=12` candidate set in the indexed Viterbi.

**Tech Stack:** TypeScript, Svelte 5 (`$state`/`$effect`/`untrack`), vitest (lib project, Node env), existing `frontend/src/lib/img2irc.ts` + `Img2IrcDialog.svelte`.

**Design doc:** `docs/plan/20260811-img2irc-smart-palette-design.md`

---

### Task 1: `smartPalette` — Palette A (k-means, K=24) pure function

**Files:**
- Modify: `frontend/src/lib/img2irc.ts` (add after `getPalToIrc` ~line 219)
- Test: `frontend/src/lib/img2irc.coverage.test.ts` (append to existing describe)

**Step 1: Write the failing test**

```typescript
import { smartPaletteA, smartPaletteB, IRC99 } from './img2irc';

it('smartPaletteA k-means returns K distinct OKLab-clustered hex colors', () => {
  const px: Uint8ClampedArray = new Uint8ClampedArray(4*4*4);
  // two clusters: 16 red-ish, 16 blue-ish
  for(let i=0;i<px.length;i+=4){ px[i]= i<128? 200:20; px[i+1]=10; px[i+2]= i<128? 20:200; px[i+3]=255; }
  const pal = smartPaletteA(px, 4, 4, 24);
  expect(pal.length).toBe(24);
  const uniq = new Set(pal.map(c=>c.toString(16))).size;
  expect(uniq).toBe(24); // distinct
  // red cluster centroid near (200,10,20), blue near (20,10,200)
  const red = pal[0], blue = pal[23];
  const r = (red>>16)&255, b = (blue>>0)&255;
  expect(r > 100).toBe(true);
  expect(b > 100).toBe(true);
});
```

**Step 2: Run test to verify it fails**

Run: `npx vitest run --project=lib src/lib/img2irc.coverage.test.ts`
Expected: FAIL — `smartPaletteA is not defined` / export error.

**Step 3: Write minimal implementation**

```typescript
export function smartPaletteA(d: Uint8ClampedArray, pW:number, pH:number, K=24): number[] {
  // gather non-transparent pixels
  const pts: number[][] = [];
  for(let y=0;y<pH;y++) for(let x=0;x<pW;x++){
    const i=(y*pW+x)*4;
    if(d[i+3] < 128) continue;
    pts.push([d[i], d[i+1], d[i+2]]);
  }
  if(pts.length===0) return [0,0,0];
  // k-means++ init in OKLab
  const oklab = pts.map(p=>srgbToOkLab(p[0],p[1],p[2]));
  const cents: number[][] = [];
  const idx0 = Math.floor(Math.random()*pts.length);
  cents.push([...oklab[idx0]]);
  while(cents.length < K){
    let best = -1, bestD = -1e12;
    for(let i=0;i<oklab.length;i++){
      let minD = Infinity;
      for(const c of cents){ const dl=oklab[i][0]-c[0], da=oklab[i][1]-c[1], db=oklab[i][2]-c[2]; minD=Math.min(minD, dl*dl+da*da+db*db); }
      if(minD > bestD){ bestD=minD; best=i; }
    }
    cents.push([...oklab[best]]);
  }
  // Lloyd iterations
  for(let iter=0; iter<20; iter++){
    const sums = cents.map(()=>[0,0,0]), counts = cents.map(()=>0);
    for(let i=0;i<oklab.length;i++){
      let bi=0, bd=Infinity;
      for(let c=0;c<cents.length;c++){ const dl=oklab[i][0]-cents[c][0], da=oklab[i][1]-cents[c][1], db=oklab[i][2]-cents[c][2]; const dd=dl*dl+da*da+db*db; if(dd<bd){bd=dd; bi=c;} }
      sums[bi][0]+=oklab[i][0]; sums[bi][1]+=oklab[i][1]; sums[bi][2]+=oklab[i][2]; counts[bi]++;
    }
    for(let c=0;c<cents.length;c++) if(counts[c]>0){ cents[c][0]=sums[c][0]/counts[c]; cents[c][1]=sums[c][1]/counts[c]; cents[c][2]=sums[c][2]/counts[c]; }
  }
  // convert centroids back to sRGB hex
  const pal = cents.map(c=>{
    const [r,g,b] = oklabToSrgb(c[0], c[1], c[2]);
    return (r<<16)|(g<<8)|b;
  });
  return pal;
}
```

Note: `oklabToSrgb` already exists in `img2irc.ts` (line ~259). `srgbToOkLab` too (line ~142).

**Step 4: Run test to verify it passes**

Run: `npx vitest run --project=lib src/lib/img2irc.coverage.test.ts`
Expected: PASS (all existing + new).

**Step 5: Commit**

```bash
git add frontend/src/lib/img2irc.ts frontend/src/lib/img2irc.coverage.test.ts
git commit -m "feat(img2irc): smartPaletteA k-means truecolor palette (K=24, OKLab)"
```

---

### Task 2: `smartPaletteB` — mIRC-99 subset (K=16)

**Files:**
- Modify: `frontend/src/lib/img2irc.ts` (after `smartPaletteA`)
- Test: `frontend/src/lib/img2irc.coverage.test.ts`

**Step 1: Write the failing test**

```typescript
it('smartPaletteB selects K distinct indices from the fixed 99, biased to frequent colors', () => {
  const px: Uint8ClampedArray = new Uint8ClampedArray(4*4*4);
  for(let i=0;i<px.length;i+=4){ px[i]=200; px[i+1]=10; px[i+2]=20; px[i+3]=255; } // all red
  const sel = smartPaletteB(px, 4, 4, 16, 0.02);
  expect(sel.length).toBeLessThanOrEqual(16);
  const uniq = new Set(sel).size;
  expect(uniq).toBe(sel.length); // injective
  expect(sel.every(i=>i>=0 && i<99)).toBe(true);
  // red mIRC index is 4 (0xff0000) or 52 (0xff0000) — one of them should be selected
  expect(sel.includes(4) || sel.includes(52)).toBe(true);
});
```

**Step 2: Run to verify fail** — `smartPaletteB is not defined`.

**Step 3: Implement**

```typescript
export function smartPaletteB(d: Uint8ClampedArray, pW:number, pH:number, K=16, lambda=0.02, mode:ColorMatching='oklab'): number[] {
  const freq = new Map<number, number>();
  for(let y=0;y<pH;y++) for(let x=0;x<pW;x++){
    const i=(y*pW+x)*4;
    if(d[i+3] < 128) continue;
    for(const idx of kNearest(d[i], d[i+1], d[i+2], IRC99, 2, false, mode)) freq.set(idx, (freq.get(idx)||0)+1);
  }
  if(freq.size===0) return [0,1,7].slice(0, Math.min(K,3));
  // greedy frequency-rank with digit bias (PaletteAssignment.lean greedy_prefix_optimal)
  const scored = [...freq.entries()].map(([idx,f])=>({idx, f, score: f / (1 + lambda*codeLen(idx))}));
  scored.sort((a,b)=> b.score-a.score || b.f-a.f || a.idx-b.idx);
  return scored.slice(0, K).map(s=>s.idx);
}
```

**Step 4: Run to verify pass.** **Step 5: Commit** `feat(img2irc): smartPaletteB mIRC-99 subset selection (greedy, digit-biased)`.

---

### Task 3: Wire `midgardMode='smart'` into `getMidgardPalette` + `is24`

**Files:**
- Modify: `frontend/src/lib/img2irc.ts:106-110` (`getMidgardPalette`), `:441` (`is24`), `:492` (`useViterbi`)
- Test: `frontend/src/lib/img2irc.coverage.test.ts`

**Step 1: Failing test**

```typescript
it('smart mode is truecolor (is24) and not viterbi-indexed', async () => {
  const opts: any = { width:4, renderMode:'ansi24', pixelMode:'half', midgardMode:'smart', viterbiW:2.5,
    colorMatching:'oklab', comic:false, dither:false, ditherMode:'none',
    alphaMode:'opaque', alphaThreshold:128, trimTransparent:false, smartEdges:true, background:'#000000' };
  const pal = getMidgardPalette(opts);
  expect(pal.length).toBe(24); // smart palette A
  const d = new Uint8ClampedArray(4*2*4).fill(128);
  const res = await renderPixelsCore(d, 4, 2, 4, 1, 'half', opts);
  expect(res.includes('\x04')).toBe(true); // truecolor emission
  expect(res.includes('\x03')).toBe(false);
});
```

**Step 2: Run → FAIL** (`smart` not handled; returns IRC99 default).

**Step 3: Implement**

- In `getMidgardPalette`: `if(o.midgardMode==='smart') return o._smartPaletteA || IRC99;` — add optional field `_smartPaletteA?: number[]` to `Img2IrcOptions` (line ~81-102).
- In `renderPixelsCore`, after `const o = ...`, compute once if `o.midgardMode==='smart'`:
  ```typescript
  if(o.midgardMode==='smart' && !o._smartPaletteA){
    // derive both palettes from d — but d is post-draw; derive at imageToIrcArt entry instead (Task 5)
  }
  ```
  For Task 3 minimal: treat `is24` as true when `midgardMode==='smart'` (so `\x04` path), and `getMidgardPalette` returns the cached `_smartPaletteA`.
- `const is24 = o.renderMode==='ansi24' || o.midgardMode==='truecolor' || o.midgardMode==='comic' || o.midgardMode==='smart'` (line 441).
- `useViterbi` (line 492) stays `!is24` → false for smart, matching truecolor greedy; Task 6 adds the truecolor Viterbi.

**Step 4: Run → PASS.** **Step 5: Commit** `feat(img2irc): wire smart mode as truecolor is24 + cached palette A`.

---

### Task 4: Derive palettes once in `imageToIrcArt` (and bitmap variant)

**Files:**
- Modify: `frontend/src/lib/img2irc.ts` (`imageToIrcArt` ~line 675, `imageToIrcArtFromBitmap` ~line 831)

**Step 1: Failing test** — convert a 2-cluster image via `imageToIrcArt` with a mocked canvas; assert the art contains `\x04` hex of the red/blue centroids.

**Step 2: Run → FAIL** (no derivation).

**Step 3: Implement**

```typescript
// inside imageToIrcArt, after `let d=id.data;` (post-draw getImageData):
if(o.midgardMode==='smart'){
  o._smartPaletteA = smartPaletteA(d, pW, pH, 24);
  o._smartPaletteB = smartPaletteB(d, pW, pH, 16, 0.02);
}
```
Same in `imageToIrcArtFromBitmap`. `Img2IrcOptions` gets `_smartPaletteA?: number[]; _smartPaletteB?: number[];`.

**Step 4: Run → PASS.** **Step 5: Commit** `feat(img2irc): derive smart palettes once per image`.

---

### Task 5: `\x04` truecolor Viterbi over Palette A

**Files:**
- Modify: `frontend/src/lib/img2irc.ts` (`renderPixelsCore` half-mode branch ~line 490-560)

**Step 1: Failing test**

```typescript
it('smart truecolor viterbi emits \\x04 with palette-A colors and sticky elision', async () => {
  const opts: any = { width:6, renderMode:'ansi24', pixelMode:'half', midgardMode:'smart',
    viterbiW:2.5, colorMatching:'oklab', comic:false, dither:false, ditherMode:'none',
    alphaMode:'opaque', alphaThreshold:128, trimTransparent:false, smartEdges:true, background:'#000000',
    _smartPaletteA: [0xff0000, 0x0000ff, 0x00ff00] };
  const d = new Uint8ClampedArray(6*2*4);
  for(let i=0;i<d.length;i+=4){ d[i]=200; d[i+1]=10; d[i+2]=20; d[i+3]=255; }
  const res = await renderPixelsCore(d, 6, 2, 6, 1, 'half', opts);
  expect(res).toContain('\x04ff0000');
});
```

**Step 2: Run → FAIL** (smart is `is24` so goes to greedy path, which emits `\x04` of raw pixels — might coincidentally pass; strengthen test to assert the *palette* color `\x04ff0000` exactly, which raw 200,10,20 wouldn't produce).

**Step 3: Implement** — in the half-mode branch, add a truecolor Viterbi when `is24 && o.viterbiW>0 && o._smartPaletteA`:
- states = `S × S` where `S = _smartPaletteA` (K=24 → 576 states, cap at 16×16=256 for speed: take 16 most-frequent).
- `cellGlyph` via `bestGlyphForState` with `pal=_smartPaletteA`.
- transitions: `pairPref`=14, `fgPref`=7 (new `pairPref24/fgPref24`), collapsed O(M·K) DP (copy existing structure, lines ~505-560, but with 24-bit costs and hex emission `'\x04'+toHex6`).

**Step 4: Run → PASS.** **Step 5: Commit** `feat(img2irc): truecolor Viterbi over smart palette A (14B/7B prefixes)`.

---

### Task 6: Palette B as indexed candidate set

**Files:**
- Modify: `frontend/src/lib/img2irc.ts` (indexed Viterbi half-mode ~line 492-507)

**Step 1: Failing test**

```typescript
it('smart indexed viterbi uses palette B as candidate set, not per-row S=12', async () => {
  const opts: any = { width:6, renderMode:'irc', pixelMode:'half', midgardMode:'smart',
    viterbiW:2.5, colorMatching:'oklab', comic:false, dither:false, ditherMode:'none',
    alphaMode:'opaque', alphaThreshold:128, trimTransparent:false, smartEdges:true, background:'#000000',
    _smartPaletteB: [4, 52, 12, 14, 2, 5, 9, 1] };
  const d = new Uint8ClampedArray(6*2*4); d.fill(128); for(let i=0;i<d.length;i+=4){ d[i]=200; d[i+1]=10; d[i+2]=20; d[i+3]=255; }
  const res = await renderPixelsCore(d, 6, 2, 6, 1, 'half', opts);
  // emitted indices must be within palette B
  const idxs = [...res.matchAll(/\\x03(\d+)/g)].map(m=>Number(m[1]));
  expect(idxs.every(i=>opts._smartPaletteB.includes(i))).toBe(true);
});
```

**Step 2: Run → FAIL** (per-row S=12 picks 12 nearest, may include non-B indices).

**Step 3: Implement** — when `o.midgardMode==='smart' && o._smartPaletteB`, use `S = o._smartPaletteB` instead of `rowPaletteForViterbi(...)` at line 507. Keep everything else (states, DP, emission) identical.

**Step 4: Run → PASS.** **Step 5: Commit** `feat(img2irc): smart indexed mode uses palette B candidate set`.

---

### Task 7: Dialog — `smart` option + derived-palette reuse

**Files:**
- Modify: `frontend/src/components/Img2IrcDialog.svelte`

**Step 1: Failing test** — extend `Img2IrcDialog` test (or lib test asserting the option string exists in the svelte source via `read`):
```typescript
it('Colors dropdown has Smart option', () => {
  const src = read('src/components/Img2IrcDialog.svelte');
  expect(src).toContain('value="smart"');
});
```
(Simple static check; the behavioral test is Task 4/5's renderPixelsCore tests.)

**Step 2: Run → FAIL.**

**Step 3: Implement**
- Line 15 `midgardMode=$state<MidgardColorMode>('xterm256')` — add `'smart'` to `MidgardColorMode` union in `img2irc.ts:79`.
- `$effect` (line 26-31): add `else if(midgardMode==='smart'){ renderMode='ansi24'; comicFilter='none'; }`.
- Dropdown (line 275-280): add `<option value="smart">Smart</option>` after True-Color.
- `resetAll` (line 254): unchanged (defaults stay xterm256).
- `getPreviewOpts` / fast preview: smart mode is `is24` so fast path naturally uses greedy truecolor (Task 5 Viterbi only when `viterbiW>0`).

**Step 4: Run → PASS (static + existing suite).** **Step 5: Commit** `feat(img2irc): Smart palette option in Colors dropdown`.

---

### Task 8: Run full verification

**Step 1:** `npx vitest run --project=lib` — expect 600+ pass (current 604 + ~8 new).
**Step 2:** `npm --prefix frontend run build` — expect 769 modules, clean.
**Step 3:** `npm --prefix frontend run test:client` — expect only pre-existing MessageList scroll failures (6), nothing new.
**Step 4:** Manual smoke: `http://127.0.0.1:5173` → upload image → select Smart → verify `\x04` art, slider drags stable (no per-drag palette reshuffle), send works.
**Step 5:** Update `docs/plan/20260811-img2irc-smart-palette-design.md` Open Questions with measured K / λ.
**Step 6:** Commit `docs(img2irc): smart palette — measured K/λ from verification`.
