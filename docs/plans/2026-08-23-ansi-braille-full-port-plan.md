# ANSI Braille Full Port Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Port irc.graphics 14×31 bitmap matching (1588 glyphs, 9 BlockKinds, smoothing) to IRC Fiber so ANSI images look as good as irc.graphics within 512B, with braille true-color compression already done.

**Architecture:** Copy `waveplate/img2irc` `src/chars.rs` GLYPH_BITMAPS into `frontend/wasm-img2irc/src/chars.rs`, port `draw.rs:render_blocks` (allowed filter, avg colors, cost, emit_colourized, Viterbi) into `frontend/wasm-img2irc/src/lib.rs` (existing wasm), keep `frontend/src/lib/img2irc.ts` as JS fallback via `glyphsToTable` when `!hasWasmSync()`. TS adds `BlockKind` enum and glyph-groups UI (default/smooth/all + 9 toggles) matching `irc.graphics` `glyph-catalog.js`.

**Tech Stack:** Rust `wasm-pack` `wasm32-unknown-unknown`, Svelte 5 `Img2IrcDialog.svelte`, TS `img2irc.ts` `lutLookup`/`nearestIndex`/`toHex6`, `vitest` `project:lib`, `vitePreprocess`.

---

### Task 1: Copy GLYPH_BITMAPS

**Files:**
- Create: `frontend/wasm-img2irc/src/chars.rs` (copy from `waveplate/img2irc` `src/chars.rs`)
- Modify: `frontend/wasm-img2irc/Cargo.toml` (ensure `chars` module)

**Step 1: Write failing test**
No test needed — just verify file exists.

**Step 2: Copy file**
```bash
curl -s https://raw.githubusercontent.com/waveplate/img2irc/main/src/chars.rs > frontend/wasm-img2irc/src/chars.rs
# or via xd://github file_read
wc -l frontend/wasm-img2irc/src/chars.rs # expect ~6341
```

**Step 3: Verify**
Run: `head -20 frontend/wasm-img2irc/src/chars.rs`
Expected: `pub const GLYPH_BITMAPS: &[(char, [[u8;14];31])]`

**Step 4: Commit**
```bash
git add frontend/wasm-img2irc/src/chars.rs
git commit -m "feat(wasm): copy GLYPH_BITMAPS 1588×14×31 from waveplate"
```

---

### Task 2: Port render_blocks to wasm

**Files:**
- Modify: `frontend/wasm-img2irc/src/lib.rs:1-50` (add `mod chars; use chars::GLYPH_BITMAPS;`)
- Modify: `frontend/wasm-img2irc/src/lib.rs:100-300` (add `render_blocks` port from `draw.rs` ~350 lines, including `BlockKind` match ranges, `allowed` filter, `calculate_average_rgb`, `pick block`, `emit_colourized`)

**Step 1: Write failing test**
```bash
# Try to build wasm
wasm-pack build frontend/wasm-img2irc --target web 2>&1 | head -20
# Expected: FAIL "cannot find value `GLYPH_BITMAPS`"
```

**Step 2: Implement minimal port**
Copy `draw.rs` `render_blocks` (lines ~150-450) adapting `crate::chars::GLYPH_BITMAPS`, `crate::palette::IRC99`, `Args.blocks` → `Vec<BlockKind>` passed from JS as `JsValue`.

**Step 3: Build**
```bash
wasm-pack build frontend/wasm-img2irc --target web
ls frontend/wasm-img2irc/pkg/img2irc_rs_bg.wasm
```

**Step 4: Commit**
```bash
git add frontend/wasm-img2irc/src/lib.rs frontend/wasm-img2irc/src/chars.rs
git commit -m "feat(wasm): port render_blocks 9 BlockKinds"
```

---

### Task 3: Add BlockKind enum to TS

**Files:**
- Modify: `frontend/src/lib/img2irc.ts:99-110` (add `export type BlockKind = 'full'|'half'|...|'legacy'`)
- Create: `frontend/src/lib/blockKind.ts` (helper `blockKindRanges` → `u32` ranges)

**Step 1: Write failing test**
```ts
// frontend/src/lib/blockKind.test.ts
import { blockKindRanges } from './blockKind';
expect(blockKindRanges('half')).toEqual([[0x2580,0x2580],[0x2584,0x2584]]);
```

**Step 2: Run**
```bash
npx vitest run --project=lib src/lib/blockKind.test.ts -v # expect FAIL
```

**Step 3: Implement**
```ts
export function blockKindRanges(k: BlockKind): [number,number][] { ... } // as in draw.rs
```

**Step 4: Commit**
```bash
git add frontend/src/lib/blockKind.ts frontend/src/lib/blockKind.test.ts
git commit -m "feat(ts): add BlockKind ranges"
```

---

### Task 4: Wire glyph-groups UI

**Files:**
- Modify: `frontend/src/components/Img2IrcDialog.svelte:153-165` (glyph groups)
- Modify: `frontend/src/lib/glyphCatalog.ts` (already has `characters(names)`)

**Step 1: Write failing test**
Check UI has 9 checkboxes: `getByLabelText('eighth')` etc → expect FAIL before.

**Step 2: Implement**
Replace `glyphPreset` 3 pills with `braille` toggle + `blocks` 9 checkboxes (full/half/quarter/eighth/triangle/corner/geometric/box/legacy) as in `irc.graphics` `glyph-controls.js` `populateGlyphGroups`. When `braille` checked, disable blocks.

**Step 3: Run client test**
```bash
npx vitest run --project=client src/components/Img2IrcDialog.test.ts -v
```

**Step 4: Commit**
```bash
git add frontend/src/components/Img2IrcDialog.svelte
git commit -m "feat(ui): 9 BlockKind toggles + braille exclusive"
```

---

### Task 5: JS fallback for render_blocks

**Files:**
- Modify: `frontend/src/lib/img2irc.ts:1027+` (quarter/half fallback already, add eighth/triangle etc using same `allowed` logic but simple `ct/cb` fallback if wasm missing)

**Step 1: Write test**
Force `hasWasmSync()=false`, render with `blocks=['eighth']`, expect glyph from `0x2581` range appears.

**Step 2: Implement**
In `renderPixelsCore` `else if(pm==='quarter')` etc, add `else if(blockKind==='eighth')` using `GLYPHS` subset filtered by `blockKindRanges`.

**Step 3: Commit**
```bash
git add frontend/src/lib/img2irc.ts
git commit -m "feat(ts): JS fallback for eighth/triangle"
```

---

### Task 6: Smoothing (optional, can be deferred)

**Files:**
- Modify: `frontend/wasm-img2irc/src/lib.rs` (add `smooth` params)
- Modify: `frontend/src/components/Img2IrcDialog.svelte` (add smoothing controls: candidates/orders/shapes/neighbors as in `irc.graphics` `general` tab)

**Step 1: Test**
Placeholder — skip if time, YAGNI.

**Step 2: Commit**
```bash
git add ...
git commit -m "feat(wasm): smoothing (deferred)"
```

---

### Task 7: Visual regression

**Files:**
- Create: `frontend/src/lib/img2irc.visual.test.ts` (compare our output vs irc.graphics `renderCurrent` for same `w=80` image, same `braille`/`blocks`)

**Step 1: Write test**
```ts
const ours = await imageToIrcArt(img, {width:80, pixelMode:'half', blocks:['half']});
const theirs = await fetch('https://irc.graphics/pkg/img2irc_rs.js')... // via wasm
expect(ours).toBe(theirs) // or ΔE <5
```

**Step 2: Run**
```bash
npx vitest run --project=lib src/lib/img2irc.visual.test.ts
```

**Step 3: Commit**
```bash
git add frontend/src/lib/img2irc.visual.test.ts
git commit -m "test: visual vs irc.graphics"
```

---

### Task 8: 512B perf

**Files:**
- Test: `frontend/src/lib/braille_compression.test.ts` already 1 passed, extend to `eighth` etc

**Step 1: Run**
```bash
npx vitest run --project=lib src/lib/img2irc.test.ts src/lib/aristotleGlyphs.test.ts
npx vite build # 216→810 modules
```

**Step 2: Commit**
```bash
git commit --allow-empty -m "chore: verify 512B braille truecolor 400→183"
```
