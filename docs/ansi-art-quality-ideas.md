# Ideas to Improve ANSI Art Quality — `img2irc` Algorithm Ladder

> Source: `midgardmud.de/tools/ans` analysis (Aristotle), `IMG2IRC_AI_BRIEF.md` §2, Lean in `RequestProject/*.lean`. All byte counts assume `IRC 512` hard / `400` safe payload and DejaVu Sans Mono coverage (`reference/glyph_coverage.txt`).

## 0. How we rank ideas

| Signal | Weight |
|---|---|
| **ΔE saved per byte** (Viterbi cost `D+λ·B`) | primary |
| **WT variance** fixed (shear/ragged) | blocker |
| **Worst-case ΔE** (mid-tone gap `0.227·contrast`) | secondary |
| **P95 wall time** @120×60 `half` | gate (`viterbi 17k transitions/row`) |

Lean tells you where the optimum *is*; the ladder tells you how cheaply you can get within `ε` of it.

---

## 1. Perceptual Colour — stop blending in sRGB

**1.1 OKLab midpoint correction (§2.5, `GlyphCoverage.perceptual_midpoint_lt_linear`)**
`((x+y)/2)³ < (x³+y³)/2`. Shade glyphs blended linearly render `+ΔL ≈ 2–4` too light. Fix: `glyphBlend` in OKLab already (`img2irc.ts:oklabToSrgb`); extend to **every** `░▒▓`/`▀▄` path and to `smartPaletteA` centroids. Directly budgets `ΔE 1–2` per shaded cell. **Done for Viterbi, TODO for `palette.test` quantisation.**

**1.2 Redmean → OKLab frontier**
Redmean weighted-RGB (`2R+4G+3B`) is `~3×` faster than OKLab `cbrt` but `~1.4×` worse ΔE on saturated reds. Use redmean for **prefilter** (`preSelect 3N→kNearest N`) and OKLab for **final `argmin`**. Gives `~60%` of OKLab quality at `~40%` cost — proven by `Clustering.centroid_minimizes` (inner-product norm → mean minimises).

**1.3 ΔE00 with L* lightness compensation**
Current `oklabDeltaE2` is `L2`. CIE ΔE00 adds `SL, SC, SH` rotation for blues. Expensive; reserve for **palette assignment** (`PaletteAssignment` Hungarian) where one decision colours `10k` pixels, not per-cell glyph loop.

---

## 2. Palette — from fixed 99 to per-image optimal

**2.1 Smart palette A+B (§2.5) — DONE**
`smartPaletteA` `K=24` k-means++ in OKLab + `smartPaletteB` frequency-rank with `λ·codeLen(idx)` bias (`λ≈0.02`, `PaletteAssignment.lean greedy_prefix_optimal`, gap `≤λ·Dmax·Σf`). Deterministic xorshift seed. Reuse across `smartFit` iterations. **Next:** joint optimisation `Σf·digits(σ)+λ·f·ΔE` as alternating Lloyd ↔ Hungarian (`Clustering.kmObjective`) — currently separate.

**2.2 α-aware k-means**
Transparent pixels currently `alpha<128` dropped. For comic/photo with soft edges, weight `α·ΔE` and centroid `Σα·x / Σα` (still minimiser by `centroid_minimizes` with weighted norm).

**2.3 Prefix-aware Viterbi candidate set**
`rowPaletteForViterbi` (10/12 colours) now picks by frequency. Include **run-length aware** score: a colour that appears in a solid run saves `pairPref` via sticky state. Add term `+ λ_run·runBytesSaved` where `runBytesSaved` ≈ `pairPref` if colour repeats. Addresses `OneDigitNonMonotone` (single-digit bias not monotone).

---

## 3. Geometry — the cell is not square

**3.1 Luminance-gap split for quarter/braille (§2.3, `Clustering.threshold_minimizes`)**
Current `>127` fixed threshold for `2×2`/`2×4` cells is `~1.2ΔE` off optimal. Optimal is **threshold at largest sorted luminance gap** (`nearestSet = thresholdSet (c₁+c₂)/2`). Already implemented in `_polygonCellMask` (64-sample 8×8, max-gap `>16` else 127); **port to `quarter`/`braille` paths** (`img2irc.ts:840`).

**3.2 Mixed-geometry tiling (§2.3)**
Let `G = {half, quarter, braille, polygon, full}`. Row cost `w(i,len,g)` (includes `bytes(g)` and segmentation penalty) → suffix DP `dpSeg` (`Segmentation.lean` `Θ(n²|G|)`, capped `Θ(n·L·|G|)`). Picks `r*=(1+cmₐₓ)/3≈0.4243` optimal block (`GlyphCoverage.optimal_block_coverage`) per region. Allows **vertical redundancy** without full 2-D DP.

**3.3 Bilateral pre-filter (§6, Midgard comic mode)**
Edge-preserving smoother `wt=exp(-d²/2σ²)` (`σ=40, r=2, 2 passes`) via WASM `bilateral_filter` + `EXP_LUT` (2048 `exp(-i/32)`). Already `tryWasmBilateral` fallback. Keep `LUT` quantization `32` steps — verified `≤0.02` error.

---

## 4. Glyph Alphabet — coverage lies

**4.1 Mask model vs coverage (`BoxMaskModel`)**
Coverage `|Δcard|·contrast` is **lower bound** for `|SΔM|·contrast` (`err_ge_coverage`, `prune_admissible`). Horizontal vs vertical stroke (`─` vs `│`) share `0.5/0.5` coverage but `Δ=32/64=0.5` mask distance (`coverage_blind_pays` + `vline_row_uniform_gap`). **Add coverage-based pruning** in `bestGlyphForState`: skip glyph if `contrast·|Δcoverage|+w·bytes ≥ best` before OKLab blend. Keeps 19→~8 checks at `w=2.5`.

**4.2 Thin-alphabet gap**
Box/box-drawing glyphs (`▌▐◤◢◥◣` masks) halve worst-case error `16→8` in atom; block `▒` worst `0.11075·contrast` vs optimal `0.0757` (`GlyphCoverage.measured_optimal_block`). Adding optimal `r*=0.4243` block would cut band error `32%`. No DejaVu glyph measures there — **synthesise** via `░+▒` dither or custom braille `⣿` dot pattern.

**4.3 Box-code budget (`BoxArmCode` + `BoxMask`)**
Box Drawing block `U+2500-257F` is perfect light/heavy code `80+space`, `29` double, `3` diagonals; all `utf8Size=3` byte-neutral vs `█`. Line economics `line_beats_space_iff 2w ≤ contrast·|S|`, `line_beats_dither_iff w < contrast·unshared`. Seam continuity triples state (`C×Fin3`, `seam_state_count 3|C|`) via `transSeam`. Use box glyphs only when `contrast·ink > 2w` — thin low-contrast wires correctly dropped.

---

## 5. Rate–Distortion & Transport

**5.1 λ-sweep is monotone (`LambdaPareto`) — DONE**
`B` antitone, `D` monotone in `λ` (`bytes_antitone`, `distortion_monotone`), every `λ>0` optimum Pareto, `fits_upward_closed` → **bisection on `viterbiW∈[0,6]` is sound**. Implemented `bisectViterbiW` (4 iters, `0.5` steps). Next: sleep `w→w+0.5` ladder `→` `bisect` to preserve monotonicity proof.

**5.2 Stream DP over rows (open)**
Current Viterbi is per-row. Need `D_row + λ·B_row` + `transSeam` + `interLineDiff` sparse/bitmask choice (`InterLineDiff` crossover `5` at `M=60, idx=2`, `least_k=⌈10/2⌉`, `payload saving 86%` at `p=0.1`). Joint DP `n·k·|G|·|S|²` — cap `L` and `S=12→144`.

**5.3 Framing & erasure (`Base94` + `Erasure`)**
`9→11` base94 is **minimal** (`256⁹≤94¹¹<256¹⁰`, rate `0.819 <50/61`, better than `9/11` needs `≥72` symbols, gain `12/11 +9.09%` over base64). Wired `base94Encode 9→11`, `erasureSingletonBound n≥k+r`. For compression: **preset LZ dictionary** trained on art corpus (per-message 400B too small for warmup) + **Base94 framing** per message + **RaptorQ `k+ε`** erasure.

---

## 6. Cost & Uniform Edges

**6.1 Head/tail at `0` cost model already exact**
`UniformHead` left indent costs `≥j+1` bytes (`bytes_ge_of_ink_at`, `indent_optimal = n` spaces in default state, `two_sided_repair ≤2·pair+N`) vs right tail free (`safeTrim` dropWhile default-blank). `spanCells` misaligned `→ +1` col/byte (`UniformHead.headSub`). Fix grid to multiples of `k`.

**6.2 Row packing `⌊C/L⌋` rows/MSG**
`msgCount_pack_le (R+k-1)/k ≤ R` (`LambdaPareto`) — pure envelope save `60×130B →20 msgs`. Requires ordered packing DP (not just `λ`).

---

## 7. Performance (why WASM matters)

Viterbi `O(M·K)` `K=144` `→17k` trans/row, 120 rows + 13 glyphs × `oklabDeltaE2` `cbrt`. Bilateral `O(W·H·r²)`. Rust `wasm-img2irc` `bilateral_filter` `39KB`; **dynamic import + `OffscreenCanvas` worker** (already `img2irc.worker.ts`, `tryWasmBatch*`, `preloadWasm`) keeps main thread `246ms → <30ms` via `postMessage` transferable `ArrayBuffer`.

---

## 8. Suggested build order (the ladder)

1. **Pruning + luma-gap** (1 day, `−15%` time, `−0.3ΔE`)
2. **OKLab per-cell only + redmean prefilter** (1 day)
3. **Smart B run-aware** (½ day)
4. **Mask pruning** (½ day)
5. **`dpSeg` mixed geometry** (2 days, `−1.5ΔE` on mixed photos)
6. **Box Drawing gated by economics** (`line_beats_*`, 1 day, `+` grid/text)
7. **Stream λ-DP + bitmask diff** (3 days, `−40%` msgs)
8. **Base94 preset dict + erasure** (2 days, `−8%` payload)

Each step keeps `lake build` green on its Lean file; `frontend/src/lib/*.test.ts` guards the `ε`.
