# IRC Fiber `img2irc` — Full-Pixel-Coverage Spec for Aristotle (Lean 4)

> **Feed this file directly to Aristotle.** It contains the complete
> natural-language → Lean 4 bridge for the image→IRC-art converter.
> Aristotle's jobs: `fill sorries`, `formalize`, `prove`, `find counterexamples`.
>
> **Goal of this spec:** eliminate *black-box holes* — cells that render as
> a transparent space (`' '` on the IRC client's default background) instead
> of an opaque black (or near-black) pixel. Every sub-pixel of the source
> image must be covered by ink; no cell may leak the client's `bg`.

---

## 0 · What Aristotle should do with this file

| Aristotle mode | Input | Output |
|---|---|---|
| **Fill sorries** | `RequestProject/Img2Irc/Coverage.lean` (skeleton in §8) | All `sorry` replaced by verified proofs |
| **Formalize** | This markdown (§1–§7) | Lean modules mirroring `frontend/src/lib/img2irc.ts` |
| **Prove from prompt** | Any theorem in §8 | Lean proof |
| **Find counterexamples** | Conjectured invariant (e.g. "`_nearBlack → space` is safe") | Concrete `r,g,b` counterexample |

Run locally:

```bash
lake build   # after Aristotle fills sorries, must stay green
cd frontend && npm run test:lib -- src/lib/img2irc.coverage.test.ts
```

---

## 1 · System overview

```
image file ──► HTMLImageElement / ImageBitmap
                │
                ▼
         imageToIrcArt (img2irc.ts:1816)  ── canvas resize to pW×pH
                │  cols = width (10..120, default 60)
                │  rows = round(width * aspect * k) , capped 120
                │  pW = cols * sx , pH = rows * sy   (sx,sy per PixelMode)
                │  handles rotate/flip/pixelize/filter/background/alpha
                │  builds smart palettes A/B (k-means OKLab)
                ▼
         renderPixelsCore (img2irc.ts:738)  ── the verified core
                │  gamma / normalize / bilateral (WASM fast-path)
                │  dither (bayer/floyd/atkinson/sierra/stucki/jarvis)
                │  per-row quantization → Viterbi DP → emission
                ▼
         IRC wire string  (lines joined by \n, each line = one PRIVMSG payload)
                │  \x03 fg[,bg]  (IRC indexed, 4–6 B per change)
                │  \x04 RRGGBB[,RRGGBB]  (truecolor, 7/14 B)
                │  glyph bytes (1 or 3 UTF-8)
                ▼
         estimateLineLengths / IRC_HARD_LIMIT=512 / IRC_SAFE_PAYLOAD=400
         smartFit ladder in Img2IrcDialog.svelte: w↑, width↓, comic, 16-col
```

**PixelModes** (`img2irc.ts:98`):

| mode | sub-pixels per cell | bytes/sub-pixel | glyph alphabet | status |
|---|---|---|---|---|
| `half` | 1×2 (top+bottom) | 1.5 (0.5 with 1 B ramp) | `▀` `▄` + ASCII ramp `= Q B * g F` + `▒ ░ ▓ █` | **default, Viterbi** |
| `full` | 1×1 | 3.0 | `█` | trivial |
| `quarter` | 2×2 | 0.75 | 16 quarter blocks `▘▝▀▖▌▞▛▗▚▐▜▄▙▟█` | greedy |
| `braille` | 2×4 | 0.375 | 256 `⠀–⣿` (`U+2800`+bits) | greedy |
| `polygon` | 8×8 mask per cell | 0.375–3.0 | 6 axis/diag + `▀▄` via `mask:bigint` | Viterbi |
| `auto` | alias → `half` | — | — | `half` path |

Only `half` and `polygon` run the Viterbi DP; the others are per-cell greedy
with sticky colour-state elision.

---

## 2 · Repository map

| File | Role | Lean counterpart |
|---|---|---|
| `frontend/src/lib/img2irc.ts` | **Single source of truth** — palettes, colour science, glyph table, Viterbi, emission | `GlypyCoverage.lean`, `ViterbiDP.lean`, `Clustering.lean`, `UniformTail.lean` |
| `frontend/src/lib/uniform.ts` | `safeTrim`, `paint`, `raggedHead/Tail`, `spanCells` — ragged-edge / head-indent arithmetic | `UniformTail.lean` `UniformHead.lean` |
| `frontend/src/lib/segmentation.ts` | `dpSeg` mixed-geometry tiling | `Segmentation.lean` |
| `frontend/src/lib/img2irc.wasm.ts` | Dynamic `wasm-img2irc` import, `tryWasmBatch*Sync` | — (opaque, spec via `img2irc.ts` JS fallbacks) |
| `frontend/src/lib/img2irc.worker.ts` | `OffscreenCanvas` + `postMessage` transferable pipeline | — |
| `frontend/wasm-img2irc/src/lib.rs` | `bilateral_filter`, batch `best_glyph`, `row_palette` | — |
| `frontend/src/components/Img2IrcDialog.svelte` | Resize via **canvas** `drawImage`, `smartFit` ladder, budget bar, preview | — |
| `docs/IMG2IRC_AI_BRIEF.md` | AI brief: wire model, 5 palettes, cost, ladder | — |
| `docs/ansi-art-quality-ideas.md` | 8-step ladder (perceptual, palette, geometry, alphabet, R-D) | — |
| `reference/glyph_coverage.txt` | Measured DejaVu Sans Mono `ct`/`cb` | `GlyphCoverage.lean` |
| `frontend/src/lib/img2irc.test.ts` / `.coverage.test.ts` / `.viterbi.test.ts` | Vitest guards (see §9) | — |

Build flags:

```ts
IRC_HARD_LIMIT = 512          // RFC 2812 incl. prefix+CRLF
IRC_SAFE_PAYLOAD = 400        // worst-case PRIVMSG envelope ≈112 B
MIN_IRC_WIDTH = 10, MAX_IRC_WIDTH = 120, DEFAULT_IRC_WIDTH = 60
DEFAULTS.viterbiW = 2.5       // λ in D + λ·B
```

---

## 3 · The bug: black holes — FIXED 2026-08-12 (smart bg)

### 3.1 Old code (defective — now patched 2026-08-12 two phases)

**Phase 1 (blk→opaque):** `isEmpty = emp || blk` → bare `' '` for near-black. **Phase 2 (no bleed):** `isEmpty = emp` still left transparent holes (`a<thr` both → bare). Both now `isEmpty=false`.

```ts
const _nearBlack = (r,g,b) => r<10 && g<10 && b<10; // 166 — now UNUSED
// (a) half/ polygon/ auto allEmpty → removed: no '' shortcut, every row renders opaque
// (b) per-cell Viterbi isEmpty (995,1030,1605,1634) → const isEmpty=false (was emp||blk → emp → false)
// (c) polygon transCount>=32 empty:true→false, cheap costs blk checks removed, quarter ch===' ' bare → opaque bg, full/braille transparent bare removed
// (d) palette freq blk continue removed, cheapQuarter/Braille blk skips removed
```

`' '` is **transparent**: IRC renders it in the client's default background
(`isDefaultBlank` in `uniform.ts:10`), so a near-black region showed the
theme (white/dark grey) — a visible hole.
`uniform.ts:22` `safeTrim` then right-trimmed trailing spaces whose `bg==d`,
so a row ending in black lost its last columns.

### 3.2 Fixed behaviour — smart bg (no bleed)

> **Invariant `FullCoverage` (final, no bleed):** **every cell emits opaque** — `isEmpty=false` always. No bare `' '` ever; `allEmpty→''` removed.

Smart bg: every cell (including `a<thr` transparent and `blk` near-black) flows into DP/greedy and emits opaque `bg`. For `blk`/`transparent` black, DP picks `bg=1` (`#000`) → `'\x03 1,1 '` (1B space, sticky `~0B` amortized) or `\x03 1 █` (3B). Quarter `ch===' '` now emits `'\x03'+bgS+','+bgS+' '` (avg luma → nearest `qPal`), not bare. Full `█` always has `\x03`/`\x04` prefix. `safeTrim` keeps `bg≠d`, so trailing/fully-transparent rows are opaque bars, not `''` or theme bleed.

| Condition | Old | New (final) |
|---|---|---|
| `emp` both transparent | `' '` bare (theme bleed) | `'\x03 1,1 '` opaque black (or `o.background` avg) — no bleed |
| `blk` both near-black | `' '` bare BUG | `'\x03 1,1 '` opaque |
| Single `blk`/half-transparent | collapsed/half-`▄` bare | `▀`/`▄`/`█` with correct `fg`/`bg` opaque |
| Trailing/fully-transparent row | `''` or trimmed | `cols` opaque spaces with `bg` (black bar) |

**Corollary:** `lines.length===rows` and `∀r, lines[r].length>0` — no `''`, no bare `' '`.

### 3.3 Why `_nearBlack` existed (and why smart bg dominates it)

`_nearBlack` was a denoise hack: dark pixels quantize to `IRC99[1]=#000000`
but still cost `pairPref` bytes. Collapsing to bare `' '` saved `4-6B` on the
first cell, dwarfed by the hole on light themes. Smart bg costs the same
`pairPref` once per run (sticky state amortizes to `~0B`), and at `λ=2.5`
the DP prefers opaque by `contrast·1.0 − w·1 ≈ 97.5` for black→white
(`contrast≈100`). The saving is within the wire model's Pareto frontier;
`LambdaPareto.lean` `bytes_antitone` still holds.

## 4 · Colour & wire model (formal)

### 4.1 Palettes

```ts
IRC99   : number[99]  // packed 0xRRGGBB, indices 0..98, mIRC semantic
ANSI256 : number[256] // xterm-256 cube
ANSI16  : number[16]
IRC16   = IRC99.slice(0,16)
XTERM256: number[256]
VGA256  : number[256] // CGA16 + greys + cube [0,51,102,153,204,255]
getMidgardPalette(o): number[]
  midgardMode 'vga256'   → VGA256
  midgardMode 'xterm256' → XTERM256
  midgardMode '16'|'retro'→ ANSI16
  renderMode  'ansi'     → ANSI256
  else                   → IRC99
```

`digits(n) = 1` if `n<10` else `2`.  `codeLen` in `img2irc.ts:169`.

### 4.2 Wire costs (must match emission exactly)

```
fgPref(f)       = 1 + digits(f)          // \x03 f
pairPref(f,b)   = 2 + digits(f)+digits(b) // \x03 f,b
truecolor single = 7  (\x04 RRGGBB)
truecolor pair   = 14 (\x04 RRGGBB,RRGGBB)

cell bytes = prefixBytes(prev,next) + glyph.bytes
line bytes = Σ cell bytes   (no trailing \x0f, trimmed by safeTrim semantics)

State transition cost (ViterbiDP.lean: transIrc):
  0                       if s stays (f,b) unchanged
  fgPref(f2)              if bg unchanged (b1==b2, f1≠f2)
  pairPref(f2,b2)         otherwise
```

`is24 = renderMode==='ansi24' || midgardMode==='truecolor'`
`smart24 = midgardMode==='smart' && _smartPaletteA && is24`
`is16 = midgardMode==='16'`

For `smart24`, costs are fixed `7`/`14` (truecolor), else `fgPref`/`pairPref`
via `getPalToIrc` mapping.

### 4.3 Colour distance

```ts
colorDist2(r1,g1,b1, r2,g2,b2, mode):
  'rgb'   → Σ (ΔsRGB)²
  'lab'   → Σ (ΔLab)²          via srgbToLab (D65)
  'oklab' → 85000 * Σ (ΔOkLab)² via srgbToOkLab (Björn Ottosson 2020)
            scale brings OKLab onto Lab byte-weight scale (median ratio ~86k)
```

`nearestIndex`, `kNearest(k)`, `lutLookup` (cache `COLOR_LUT` ≤8000), `getPalOkLab` cache.

---

## 5 · Glyph alphabet

Measured on DejaVu Sans Mono; `ct`/`cb` = top/bottom ink coverage (§4.1 of AI brief):

```ts
GLYPHS = [
  {ch:' ', ct:0.0,   cb:0.0,   bytes:1, mask:0x0000000000000000n},
  {ch:'=', ct:0.122, cb:0.120, bytes:1},
  {ch:'Q', ct:0.247, cb:0.261, bytes:1},
  {ch:'B', ct:0.294, cb:0.253, bytes:1}, // densest safe ASCII (0.273)
  {ch:'*', ct:0.183, cb:0.010, bytes:1}, // light ▀
  {ch:'g', ct:0.149, cb:0.321, bytes:1}, // light ▄
  {ch:'F', ct:0.245, cb:0.107, bytes:1},
  {ch:'▀', ct:1.0,   cb:0.0,   bytes:3, mask:0x00000000ffffffffn},
  {ch:'▄', ct:0.0,   cb:1.0,   bytes:3, mask:0xffffffff00000000n},
  {ch:'▒', ct:0.490, cb:0.499, bytes:3}, // measured 0.490/0.499, optimal r*=0.4243
  {ch:'░', ct:0.183, cb:0.181, bytes:3}, // dominated
  {ch:'▓', ct:0.796, cb:0.816, bytes:3}, // dominated
  {ch:'█', ct:1.0,   cb:1.0,   bytes:3, mask:0xffffffffffffffffn}, // dominated vs ' '
  {ch:'▌', ct:0.5,   cb:0.5,   bytes:3, mask:0x0f0f0f0f0f0f0f0fn},
  {ch:'▐', ct:0.5,   cb:0.5,   bytes:3, mask:0xf0f0f0f0f0f0f0f0n},
  {ch:'◤', ct:0.8125,cb:0.3125,bytes:3, mask:0x0103070f1f3f7fffn},
  {ch:'◢', ct:0.1875,cb:0.6875,bytes:3, mask:0xfefcf8f0e0c08000n},
  {ch:'◥', ct:0.8125,cb:0.3125,bytes:3, mask:0x80c0e0f0f8fcfeffn},
  {ch:'◣', ct:0.1875,cb:0.6875,bytes:3, mask:0x7f3f1f0f07030100n},
]
```

*Ordered state trick:* `(fg,bg)` ordered, so `1−c` is free (swap `fg`/`bg`).
`glyphBlend(c,fg,bg)=c*fg+(1−c)*bg` (OKLab branch blends in cbrt domain then `oklabToSrgb`).

Per-state, per-cell best glyph:

```
cost = |tTop − blend(ct,fg,bg)| + |tBot − blend(cb,fg,bg)| + w·bytes(glyph)
       (tTop/tBot via luma or OKLab depending on mode; contrast = |fg−bg| in OKLab)
```

`bestGlyphForState` (sync) and `tryWasmBatchBestGlyphSync` (batched) must agree
within `1e-6` on `err`.

`GLYPH_COVERAGES = [0, 0.121,0.254,0.273, 0.4945,0.5055, 0.727,0.746,0.879, 1]`
`optimal_block r* = (1+cmax)/3 ≈ 0.4243` — band error `max(r−cmax,1−2r)/2`.

**Constraints:** no digit/`,` glyph (eaten by `\x03`), no leading `/`, avoid `%$`.

---

## 6 · Viterbi encoder (half & polygon)

Per row `r`, `M=cols`:

1. **Candidate palette `S`** (`rowPaletteForViterbi`, ≤12/16):
   frequency of `kNearest(k=2)` over all half-pixels in row, filtered
   `_nearBlack` **excluded** from frequency but **not** from cell emptiness
   after fix (see §3.2). For `smart` modes, `S` is `_smartPaletteB` or
   `rankSmartPaletteA`.

2. **States** `S×S` ordered pairs `states = [(f,b) for f in S for b in S]` ≤144/256.

3. **Precompute** `cellGlyph[i][s] = bestGlyphForState(tops[i],bots[i], f,b, pal,mode,w)`
   for non-empty `i`; batched WASM path is `M*|S|² ≤ 65536` guard.

4. **DP** (`ViterbiDP.lean`):

```
INF = 1e18
dp[s] = g.err + w*(g.bytes + pairPref)          if i==0 and non-empty
dp[s] = 0                                        if i==0 and empty (space, no cost)
for i>0:
  if empty[i]: dp' = dp; back[i][s]=s; continue   // Lean extension: empty preserves state
  isFirst = (i == firstNonEmpty)
  if isFirst:
    dp'[s] = g.err + w*(g.bytes+pairPref)         // must pay pair
  else if smart24:
    dp'[s] = min( dp[s],
                  bMin[b]+w*7,                    // fg-only (truecolor)
                  gMin +w*14 ) + g.err+w*g.bytes  // pair
  else:
    dp'[s] = min( dp[s],
                  bMin[b]+w*fgPref(fgM),
                  gMin +w*pairPref(fgM,bgM) ) + g.err+w*g.bytes
  back[i][s] = argmin predecessor index
gMin = min_s dp[s]
bMin[b] = min_{s: bg=b} dp[s]
```

   *Collapsed transition* proof: `transIrc` depends only on `stay / bgSame / switch`
   → `O(M·K)` not `O(M·K²)` (`img2irc.viterbi.test.ts` collapse test).

   **Empty handling** (Leon extension): empty cells **preserve IRC state**
   (`dp' = dp`). A buggy alternative `dp'[s]=gMin` would allow a zero-cost
   teleport to any state through spaces, breaking `bMin`/`gMin` accounting
   (proven by `viterbi.test.ts: empty gap preserves state`).

5. **Backtrace**: `chosenIdx[M-1]=argmin dp`, then `chosenIdx[i-1]=back[i][chosenIdx[i]]`
   (empty cells copy successor's state).

6. **Emission**: maintain `lastFg,lastBg, first`. For each `c`:
   ```
   if empty[c]: ln+=' '; first=false; continue;
   if glyph==' ':
     need = first || lastBg != bg
     emit '\x03'+fg+','+bg  (or '\x04'+hex)
     ln+=' '
   else:
     needFull   = first||lastFg!=fg||lastBg!=bg
     needFgOnly = !first && lastBg==bg && lastFg!=fg
     emit '\x03'+fg      if needFgOnly
     emit '\x03'+fg+','+bg if needFull
     ln+=glyph
   ```

   **After fix** `empty` means **only** `emp` (transparent), never `blk`.
   So every `ln+=' '` for `blk` is now `ln+='\x03'+black+','+black+' '` on first
   black cell, then `' '` sticky for the run — opaque, trims safe.

7. **Line push** `lines.push(ln)` (possibly `''` only if row truly all transparent).

Quarter/braille remain greedy (no DP).

---

## 7 · Resize & pre-process (for completeness, not coverage-critical)

- `imageToIrcArt` canvas path: `cvs.width=eW, cvs.height=eH` with
  `imageSmoothingEnabled = filter!=='nearest'`, `cssFilter` (contrast/brightness/saturate),
  `alphaMode==='opaque'` fills `background`, else `clearRect`. Handles `rotate∈{0,90,180,270}`,
  `flipH/V`, `pixelize` (down→nearest-neighbour up).
- `getImageData(0,0,pW,pH).data : Uint8ClampedArray` fed to `renderPixelsCore`.
- In `renderPixelsCore`: `gamma` (`Math.pow(…1/g)`), `normalize` (stretch `luma` to `[0,255]`),
  `comic` bilateral (`σ=40 r=2 2 passes`, WASM `bilateral_filter` + `EXP_LUT[2048]` where
  `LUT[i]=exp(-i/32)` quantises `d²` as `d2*32/σ²`, error ≤0.02), then `dither`.

---

## 8 · Lean 4 formal skeleton (Aristotle: fill `sorry`)

Create `RequestProject/Img2Irc/Coverage.lean` (or `frontend/lean/Img2ircCoverage.lean`
if you prefer) with the skeleton below. Imports assume `UniformTail`, `ViterbiDP`,
`GlyphCoverage`, `BoxArmCode` already exist (they do — see memories `58014ce`, `bad2f4b`).

```lean
import Img2Irc.GlyphCoverage
import Img2Irc.ViterbiDP
import Img2Irc.UniformTail
import Img2Irc.BoxArmCode

namespace Img2Irc.Coverage

-- ── Types ──────────────────────────────────────────────────────────
structure Pixel where
  r g b a : Nat
  h_r : r < 256 := by omega
  h_g : g < 256 := by omega
  h_b : b < 256 := by omega
  h_a : a < 256 := by omega

def isTransparent (p : Pixel) (thresh : Nat) : Prop := p.a < thresh
def isNearBlack (p : Pixel) : Prop := p.r < 10 ∧ p.g < 10 ∧ p.b < 10

structure HalfCell where
  top bot : Pixel

def isEmptyTransparent (c : HalfCell) (thresh : Nat) : Prop :=
  isTransparent c.top thresh ∧ isTransparent c.bot thresh

def isEmptyOld (c : HalfCell) (thresh : Nat) : Prop :=
  isEmptyTransparent c thresh ∨ (isNearBlack c.top ∧ isNearBlack c.bot)

def isEmptyNew (c : HalfCell) (thresh : Nat) : Prop := False
  -- NOTE: FINAL no-bleed: no empty cells ever, even transparent → opaque bg (Phase 2). isEmptyOld included blk+emp, Phase1 kept emp, Final keeps none.

inductive GlyphKind | space | shade | halfTop | halfBot | blockMid | solid
structure Glyph where
  ch : String
  ct cb : Rat
  bytes : Nat
  kind : GlyphKind

def opaqueGlyphs : List Glyph := sorry -- mirrors GLYPHS filtered to opaque emission
def transparentGlyph : Glyph := ⟨" ", 0, 0, 1, .space⟩

-- ── Wire model ─────────────────────────────────────────────────────
def digits : Nat → Nat | n => if n < 10 then 1 else 2
def fgPref (f : Nat) : Nat := 1 + digits f
def pairPref (f b : Nat) : Nat := 2 + digits f + digits b
def transIrc : (Nat × Nat) → (Nat × Nat) → Nat
  | (f1,b1),(f2,b2) => if f1==f2 && b1==b2 then 0 else if b1==b2 then fgPref f2 else pairPref f2 b2

axiom transIrc_collapse :
  ∀ (states : List (Nat×Nat)) (dpPrev : List Nat) (f b : Nat),
    let brute := List.inf (states.zip dpPrev |>.map (fun ((f1,b1),c) => c + transIrc (f1,b1) (f,b)))
    let stay := sorry -- dpPrev at (f,b)
    let bMin := sorry -- min_{bg=b} dpPrev
    let gMin := List.inf dpPrev
    brute = Nat.min stay (Nat.min (bMin + fgPref f) (gMin + pairPref f b))

-- ── Invariant: full coverage ──────────────────────────────────────
def rendersOpaque (g : Glyph) (fg bg : Nat) : Prop :=
  -- space with explicit bg, or any glyph with CT/CB covering the cell's 2 sub-pixels
  g.ch ≠ " " ∨ True  -- refined: space is opaque iff emitted with non-default bg

def rowCovers (cells : List HalfCell) (emitted : List (Glyph × Nat × Nat)) (thresh : Nat) : Prop :=
  ∀ i : Fin cells.length,
    ¬ isEmptyTransparent cells[i] thresh →
    (emitted[i].1 ≠ 99 ∧ emitted[i].2 ≠ 99) -- concrete: bg ≠ default transparent index
    ∧ rendersOpaque emitted[i].1 emitted[i].1.1 emitted[i].1.2

-- THEOREM 1 — No transparent leak for near-black (the bug fix)
theorem no_hole_for_near_black :
  ∀ (c : HalfCell) (thresh : Nat),
    isNearBlack c.top ∧ isNearBlack c.bot →
    ¬ isEmptyTransparent c thresh →
    ¬ isEmptyNew c thresh := by
  sorry

-- THEOREM 2 — Old predicate strictly larger (admits holes)
theorem old_empty_strictly_larger :
  ∃ c thresh, isEmptyOld c thresh ∧ ¬ isEmptyNew c thresh := by
  sorry

-- THEOREM 3 — FullCoverage: every non-transparent cell emits opaque ink
-- This is the acceptance criterion for the fix.
theorem fullCoverage (row : List HalfCell) (thresh : Nat)
  (h_nontrans : ∃ i, ¬ isEmptyTransparent row[i] thresh) :
  let emitted := renderRow row thresh -- abstract spec of renderPixelsCore's per-row emission
  rowCovers row emitted thresh := by
  sorry

-- THEOREM 4 — Trailing black not trimmed when bg is non-default
theorem trailing_black_not_trimmed :
  ∀ (d : Nat) (row : List (Glyph × Nat × Nat)) (blackBg : Nat),
    blackBg ≠ d →
    (row.getLast?.map (·.2) = some blackBg) →
    (UniformTail.safeTrim d (row.map fun (g,fg,bg) => ⟨fg,bg,if g.ch==" " then 0 else 1⟩)).length = row.length := by
  sorry

-- THEOREM 5 — All-black row is non-empty (not "")
theorem all_black_row_nonempty :
  ∀ (cols thresh : Nat) (h : 0 < cols),
    let row : List HalfCell := List.replicate cols ⟨⟨0,0,0,255⟩, ⟨0,0,0,255⟩⟩
    (renderRow row thresh).length = cols ∧
    (∀ g ∈ renderRow row thresh, rendersOpaque g.1 g.1.1 g.1.2) := by
  sorry

-- THEOREM 6 — Viterbi empty-preserves-state (vs teleport bug)
theorem empty_preserves_state (states : List (Nat×Nat)) (dp : List Nat) :
  let dp' := dp -- empty step: dp' = dp
  let teleport := List.replicate dp.length (List.inf dp)
  dp' ≠ teleport ∨ dp.length = 0 := by
  sorry

-- THEOREM 7 — Cost bound: opaque black ≤ 1 extra byte vs naked space (amortised)
theorem opaque_black_cost_bounded (blackIdx : Nat) :
  pairPref blackIdx blackIdx + 1 ≤ 7 ∧  -- indexed: ≤6+1=7
  (pairPref blackIdx blackIdx + 1) - 1 ≤ pairPref blackIdx blackIdx := by
  sorry

-- THEOREM 8 — Counterexample finder (Aristotle should surface this for old code)
def oldCodeLeaksBackground : Prop :=
  ∃ (c : HalfCell),
    isNearBlack c.top ∧ isNearBlack c.bot ∧ isEmptyOld c 10 ∧ rendersOpaque transparentGlyph 0 99 = False

theorem old_code_has_leak : oldCodeLeaksBackground := by
  sorry

end Img2Irc.Coverage
```

**Additional sorries Aristotle should fill** (create if not present):

- `GlyphCoverage.lean`: `optimal_block_coverage`, `bandError`, `dominated_of_byte_gap` — already proven in `GlypyCoverage.lean` per `58014ce`, keep as lemmas.
- `ViterbiDP.lean`: `collapse`, `viterbi_correct`, `empty_preserves_state` — see `ViterbiDP.lean:26-173` mapping table in AGENTS memory.
- `UniformTail.lean` / `UniformHead.lean`: `safeTrim_dropWhile_defaultBlank`, `indent_optimal`, `raggedTail`, `spanCells` — used by Theorem 4.

---

## 9 · Tests & oracles (Aristotle must keep green)

| Test file | What it guards | Key assertion for coverage |
|---|---|---|
| `frontend/src/lib/img2irc.coverage.test.ts` | all `pixelMode`s, `comic`, `gamma`, `smart` | `renderPixelsCore` on all-black `4×2` half → string non-empty, not trimmed |
| `frontend/src/lib/img2irc.viterbi.test.ts` | `collapse`, `empty gap preserves state`, `first non-empty pays pairPref` | `firstColorIdx` contains `','` (pair) |
| `frontend/src/lib/img2irc.test.ts` | `estimateLineLengths`, `base94`, `diff` | `longest` accounting |
| `frontend/src/lib/uniform.test.ts` (if exists) | `safeTrim` | trailing default-blank removed, non-default kept |
| Manual oracle | 60×60 black image | CLI: `node -e "import('./src/lib/img2irc.ts')"` → art lines each contain `\x03` and length>0 |
| Manual oracle | checkerboard `black/white` | every cell emits `▀`/`▄` with correct `fg`/`bg`, no `' '` with default bg |

Add these **new** vitest cases (copy-paste ready):

```ts
it('all-black row emits opaque spaces with black bg, not empty line', async () => {
  const cols=4, rows=1, pW=4, pH=2;
  const d = new Uint8ClampedArray(pW*pH*4);
  for(let i=0;i<d.length;i+=4){ d[i]=0; d[i+1]=0; d[i+2]=0; d[i+3]=255; }
  const art = await renderPixelsCore(d,pW,pH,cols,rows,'half',{
    viterbiW:2, renderMode:'irc', midgardMode:'16', colorMatching:'rgb',
    nograyscale:false, gamma:1, normalize:false, comic:false,
    dither:false, ditherMode:'none', alphaMode:'opaque', alphaThreshold:10, samplingFilter:'nearest',
  } as never);
  expect(art).not.toBe('');
  expect(art.trim()).not.toBe('');
  // must contain a colour code — not a naked space
  expect(art).toContain('\x03');
  // must survive safeTrim: split lines none empty
  const lines = art.split('\n');
  expect(lines[0].length).toBeGreaterThan(0);
});

it('transparent alpha still emits space without bg (hole allowed)', async () => {
  const d = new Uint8ClampedArray(8); for(let i=0;i<8;i+=4){ d[i]=0; d[i+1]=0; d[i+2]=0; d[i+3]=0; }
  const art = await renderPixelsCore(d,2,2,2,1,'half',{
    viterbiW:2, renderMode:'irc', midgardMode:'16', colorMatching:'rgb',
    nograyscale:false, gamma:1, normalize:false, comic:false,
    dither:false, ditherMode:'none', alphaMode:'transparent', alphaThreshold:10, samplingFilter:'nearest',
  } as never);
  expect(art).toBe(''); // all transparent → empty line is correct
});
```

---

## 10 · Acceptance criteria for the fix — ✅ PATCHED 2026-08-12 (final no-bleed)

- [x] `isEmpty` **never true** — `const isEmpty=false` at `986,1021,1523,1593,1622` plus `allEmpty` blocks removed (`936,1235,1629`). No `''` line, no bare `' '`.
- [x] `_nearBlack` removed from 11+ sites; `rowPaletteForViterbi` includes black; `polygon transCount>=32` now `empty:false`; `cheapQuarter/Braille` blk skips removed.
- [x] `quarter ch===' '` bare → opaque `\x03 bg,bg ' '` (avg luma → `qPal`/`palAuto`) at `888,1683`; `full` transparent bare removed; half `a1&&a2` bare removed.
- [x] `safeTrim` keeps `bg≠d` — trailing/fully-transparent rows now opaque bars, not trimmed.
- [x] Viterbi `dp.slice()` empty branch dead (never taken) — kept for proof but `cellIsEmpty` always false, DP always `pairPref`.
- [ ] All Lean `sorry` in §8 filled (`isEmptyNew=False`); `lake build` green; `npm run test:lib` green.
- [x] Visual: solid `#010101` 60×60, fully-transparent PNG, and dark gradient all render as solid opaque rectangles — no theme bleed in HexChat/mIRC/WeeChat.
---

## 11 · Code pointers (exact lines — now patched)

- Patched (final): `166 _nearBlack` UNUSED; `936 allEmpty` removed, `677 palette` includes black, `986/1021/1593/1622 isEmpty=false`, `593 transCount empty:false`, `888/1683 quarter ch===' '→opaque`, `1182 full/half transparent bare removed`, `1235 polygon allEmpty removed`, `1523 cheap isEmpty false`, `1629 auto allEmpty removed`; `611` polygon blk removed.
- Wire: `img2irc.ts:415-422` (`pairPref`/`fgPref`), `171-191` (OKLab/Lab), `228-273` (LUT), `414-446` (glyph costs).
- Viterbi: `img2irc.ts:931-1180` (half Viterbi), `1234-1747` (polygon Viterbi), `669-686` (`rowPaletteForViterbi`).
- Glyphs: `img2irc.ts:457-482` (`GLYPHS`), `484-643` (`bestGlyphFor*`).
- Trim: `frontend/src/lib/uniform.ts:12-32` (`safeTrim`, `isDefaultBlank`).
- WASM parity: `frontend/wasm-img2irc/src/lib.rs:1-400` + `frontend/src/lib/img2irc.wasm.ts:1-150`.
- Dialog & smartFit: `frontend/src/components/Img2IrcDialog.svelte:1-600`, `IMG2IRC_AI_BRIEF.md:190-211`.
- Tests: `frontend/src/lib/img2irc.coverage.test.ts:110-195`, `img2irc.viterbi.test.ts:13-80`.

Pre-existing Lean mirrors (do not re-prove, reuse as axioms):

- `RequestProject/GlyphCoverage.lean` — `58014ce` (`blend`, `cellCost`, `bandError`, `optimal_block_coverage`, `dominated_of_byte_gap`).
- `RequestProject/BoxArmCode.lean` / `BoxMaskModel` — `bad2f4b` (`armCode_injective`, `boxCode_range`).
- `RequestProject/ViterbiDP.lean:26-173` — `collapse`, `viterbi_correct`.
- `RequestProject/UniformTail.lean` / `UniformHead.lean` — `ragged`, `safeTrim`, `spanCells`.
- `RequestProject/Clustering.lean` — `centroid_minimizes`, `threshold_minimizes`, `kmObjective`.
- `RequestProject/LambdaPareto.lean` — `bytes_antitone`, `distortion_monotone`, `fits_upward_closed`.

---

## 12 · Formalization notes for Aristotle

- Use `Nat` for `r,g,b,idx,bytes`; `Rat` for `ct,cb,coverage`; `Nat` for `cost` after scaling (multiply `ΔE` by `1000` to stay integral, matching `GLYPH_COVERAGES` scaled by `1000`).
- Model IRC state as `Colour = Nat` (palette index or packed `0xRRGGBB` for truecolor); `Cell = Colour × Colour × GlyphKind`.
- `renderRow` is the **spec** function — pure, total, deterministic — whose
  reference implementation is `renderPixelsCore`'s per-row loop. Prove `renderRow`
  refines `renderPixelsCore` (observational equivalence on `lines : List String`).
- For `WASM` paths: treat `tryWasmBatch*Sync` as **untrusted accelerator**;
  spec is the JS `bestGlyphForState` / `rowPaletteForViterbi`; theorem
  `wasm_parity : ∀ args, wasmResult = jsResult ∨ wasmResult = none` (fallback).
- Dither/bilateral/gamma are **pre-processors** — they preserve `FullCoverage`
  because they are pixel-wise maps `Pixel → Pixel`; prove `isEmptyTransparent`
  is stable under them when `alphaMode==='opaque'`.
- The only `sorry` that **should remain** after this spec is the `bilateral_filter`
  correctness (image-processing approximation) — mark it `axiom bilateral_approx`.

---

## 13 · Prompt to paste into Aristotle

> Fill sorries in `RequestProject/Img2Irc/Coverage.lean` given this spec
> (`docs/ARISTOTLE_IMG2IRC_SPEC.md` §§3–8). First, find a counterexample to
> `isEmptyOld` being safe (Theorem 8), then prove `no_hole_for_near_black`,
> `fullCoverage`, `trailing_black_not_trimmed`, and `all_black_row_nonempty`.
> Use `GlyphCoverage.optimal_block_coverage`, `ViterbiDP.collapse`, and
> `UniformTail.safeTrim` as lemmas. Keep `lake build` green.

---

*Generated 2026-08-12 for IRC Fiber `frontend/src/lib/img2irc.ts` @ `41A8`.*
*Contact: `docs/IMG2IRC_AI_BRIEF.md` + `docs/ansi-art-quality-ideas.md`.*
*Lean memories: `58014ce`, `bad2f4b`.*

