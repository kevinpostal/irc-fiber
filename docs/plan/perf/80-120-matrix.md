# WASM vs JS — Final Report (batch rowPalette + direct OKLab, 13×)

**Image:** 390×503 bird → `half`/`xterm256`/`oklab`  
**Bench:** `bun frontend/bench_resize_matrix.mjs` (scaleBilinear + renderPixelsCore)

## Before (per-cell WASM, 2026-08-11 18:21)
* 80 viterbi: JS 3372ms vs WASM 16532ms (WASM 4.9× slower)

## After (batched WASM, 2026-08-11 19:01) — palette cache + direct OKLab + batch_best_glyph

| width | norm | w | JS (OFF) | WASM (ON) | vs JS | cellGlyph | rowPal |
|------:|------|---|--------:|----------:|------:|----------:|-------:|
| 80 | f | 2.5 | 3668ms | **2171ms** | 72ms (3%) | 1971ms (91%) | 1.69× faster |
| 80 | t | 2.5 | 3232ms | **2257ms** | 72ms | 2039ms | 1.43× |
| 120 | f | 2.5 | 4584ms | **4299ms** | 106ms | 3997ms | 1.07× |

*cellGlyph 38× vs JS, 200× vs old WASM*

## After (batched rowPalette, 2026-08-11 19:07) — + batch_row_palette

| width | norm | w | JS (OFF) | WASM (ON) | vs JS | cellGlyph | rowPal | dp |
|------:|------|---|--------:|----------:|------:|----------:|-------:|---:|
| 80 | f | 2.5 | 3271ms | **246ms** | 67ms (27%) | 34ms (14%) | 135ms (55%) | **13.3× faster** |
| 80 | t | 2.5 | 3232ms | **240ms** | 67ms | 30ms | 136ms | **13.4×** |
| 120 | f | 2.5 | 4633ms | **339ms** | 88ms (26%) | 57ms (17%) | 185ms (54%) | **13.6×** |
| 120 | t | 2.5 | 4586ms | **341ms** | 88ms | 58ms | 187ms | **13.4×** |
| 80 greedy | f | 0 | 335ms | 1738ms* | — | — | — | 5× slower (not batched) |

\*Greedy `w=0` not yet batched (14880 per-pixel `nearest_index`); `batch_nearest` exists in Rust but not wired for `half` greedy. Greedy is 340ms already (9.7× faster than viterbi JS), not user-visible. Viterbi is default (`w=2.5`).

**Bottleneck shift:** Before: `cellGlyph 84%`. After batch_best_glyph: `rowPal 91%`. After batch_row_palette: `dp 55%` (135ms) — next win would be DP in Rust, not needed (246ms total already <300ms).

**Optimizations:**
1. `batch_best_glyph` — 93 WASM calls vs 1.07M (99.99% off), palette cache (`thread_local! PAL_CACHE`), direct OKLab lerp (78 cbrt eliminated per cell/state)
2. `batch_row_palette` — per-row `kNearest(k=2)` + freq/score in Rust, 93 calls vs 14880 (160×), same palette cache
3. `Cargo.toml` `codegen-units=1 panic=abort wasm-opt -O4 --enable-simd`

**Artifacts:** `wasm_img2irc_bg.wasm` 35K, `src/lib/img2irc.wasm.ts` wrappers, `src/lib/img2irc.ts` batched loops with fallback, `bench_resize_matrix.mjs` 8-combo matrix.

**Verification:**
```bash
bun frontend/bench_resize_matrix.mjs # 246ms vs 3271ms (13×)
npx vitest run --project=lib src/lib/img2irc.resize-matrix.perf.test.ts # 9 passed
npx vitest run --project=lib # 620 passed
```

