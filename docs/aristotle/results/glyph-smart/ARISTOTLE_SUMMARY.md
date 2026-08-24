# Summary of changes for run 7b279b6b-1c30-43c8-b41a-bde8a3d94e22
## What was delivered

**1. The Lean derivation — `frontend/wasm-img2irc/lean/GlyphSmart.lean` (783 lines, no `sorry`, no extra axioms).**
`lake build` builds it cleanly; `grep "theorem fits_512"` finds it, and `#print axioms` on every headline theorem shows only `propext` / `Quot.sound` / `Classical.choice`.

All arithmetic is exact integer arithmetic (no floats, no reals): coverages live in units of `1/30000`, a scale divisible both by 10000 — the finest denominator in `GLYPH_COVERAGES` — and by 3, so `(1+cmax)/3` is exact. The hard constants appear literally: `IRC_HARD_LIMIT=512`, `IRC_SAFE_PAYLOAD=400`, `GLYPH_COVERAGES=[0,121/1000,254/1000,273/1000,4945/10000,5055/10000,727/1000,746/1000,879/1000,1]`, `GLYPH_BYTES_SPACE=1`, `GLYPH_BYTES_HALF=3`, `MIN_IRC_WIDTH=10`, `viterbiW ∈ [0,6] step 0.5`.

Theorems proved:
- `optimal_block_coverage` — `r* = (1+cmax)/3` minimises `bandError cmax r = max(r-cmax, 1-2r)/2` over *all* coverages; for `cmax = 0.273`, `r* = 0.42433… ≈ 0.4243`, with `bandError_at_optimum` giving the value `(1-2cmax)/6`.
- `bandError_optimal_beats_measured` — `0.075667` at `r*` against `0.1105` at the measured `▒` coverage `0.494`: an improvement of `1045/3315 = 31.5%` (stated as the checkable bound ≥ 31%; 31.5% is what rounds to the 32% quoted in the request).
- `dominatedByByteGap` — the byte-gap test is *sound*: when `(|Δct|+|Δcb|)·contrast ≤ w·Δbytes`, the cheaper glyph's `cellCost` is no larger on **every** cell, for every target-luma pair.
- `pareto_optimal` (and `pareto_optimal_sweet_spot` for `viterbiW ∈ [2,4]`) — pruning to the byte-gap Pareto frontier never raises the achievable cell cost, so no alphabet using more bytes beats it; the frontier is antitone in `w`.
- `fits_upward_closed`, `bisect_fits`, `bisect_minimal`, `bisect_in_range` — the feasible set is upward closed because the byte count is antitone in `λ`, and the 4-iteration bisection (first probe at the `w = 2` sweet spot, 13 grid points) returns the *least* feasible weight.
- `widthStep_ge_min`, `widthStep_fits_or_min` — the width shrink steps by 4 and stops at a fitting width or at 10.
- `fits_512` — the pipeline output is always ≤ 512 bytes including the 112-byte prefix reserve.
- `exists_optimal_alphabet_fitting_512` — the requested `∃ alphabet K, ∀ cell, cellCost minimal ∧ Σ bytes ≤ 512`.
- `standardAlphabet_frontier_sizes` / `standardAlphabet_flat_cell_is_space` — the 18 candidate glyphs prune to 15 at `w = 2` and 13 at `w = 4` for a mid-contrast cell (inside the 12..18 window), and to the single 1-byte space in a flat cell.

The encoder itself is abstracted by an `Encoder` structure carrying exactly the four facts the pipeline relies on (per-cell byte bound, antitone in `w`, monotone in width, non-increasing under palette downgrade); `boundEncoder` witnesses that these are satisfiable, so nothing is vacuous.

**2. The pure frontend function — `frontend/src/lib/aristotleGlyphs.ts`.** No runtime calls, no dependencies: constants, `bandError`, `optimalBlockCoverage`, `glyphCellCost`, `glyphDominatedByByteGap`, `paretoPrune`/`pruneAlphabet`, `bisectViterbiW`, `pickFitStep`, `downgradePalette`, and `compressToFit` implementing the order *glyph pruning → bisection → width shrink → palette downgrade → final guard* (`"Image too detailed for 512B at 10 cols"`). `frontend/src/lib/aristotleGlyphs.smoke.mts` reproduces the Lean numbers and passes (0.4243, 0.075667 vs 0.1105, 31.52%, frontier sizes 15/13/1, 512-byte bound, guard behaviour).

**3. The original sketch.** `IrcFiber/GlyphSmart.lean` now imports the finished module and re-exports corrected versions under the original names; the original text is kept verbatim in a block comment with a note on each item. Two of its statements were false as written (`fits_512` fails for `width = 11, bytes_per_cell = 100`; `pareto_optimal` fails for the empty alphabet), three were vacuous or mere `rfl`, and `glyphBlend` had a precedence bug (`c*fg + (1000-c)*bg/1000` divides only the second term) — all explained in the file header.

Also fixed: `lake-manifest.json` had an empty package name, which prevented the workspace from configuring at all; both libraries are now default build targets. Documentation is in `frontend/wasm-img2irc/lean/README.md`.

The archive `/tmp/glyph-smart-result.tar.gz` was written, and all work is committed and pushed.
