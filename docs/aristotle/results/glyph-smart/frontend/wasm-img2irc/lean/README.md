# GlyphSmart — derived algorithm for Smart detail glyph selection + 512B compression

Everything here is offline and deterministic: the Lean file
[`GlyphSmart.lean`](./GlyphSmart.lean) is the specification and proof, and
[`frontend/src/lib/aristotleGlyphs.ts`](../../src/lib/aristotleGlyphs.ts) is the pure
function baked into the frontend.  There are no runtime calls to anything.

Build and check:

```
lake build                 # builds GlyphSmart and IrcFiber, no sorry, no extra axioms
grep "theorem fits_512" frontend/wasm-img2irc/lean/GlyphSmart.lean
node --experimental-strip-types frontend/src/lib/aristotleGlyphs.smoke.mts
```

## Hard constants

| constant | value | source |
|---|---|---|
| `IRC_HARD_LIMIT` | 512 | img2irc.ts:154 — RFC 2812, incl. prefix + CRLF |
| `IRC_SAFE_PAYLOAD` | 400 | img2irc.ts:157 — leaves ~112 for PRIVMSG prefix/tags |
| `GLYPH_COVERAGES` | `[0, 121/1000, 254/1000, 273/1000, 4945/10000, 5055/10000, 727/1000, 746/1000, 879/1000, 1]` | img2irc.ts:480 |
| `GLYPH_BYTES_SPACE` | 1 | img2irc.ts:561 |
| `GLYPH_BYTES_HALF` | 3 | img2irc.ts:561 |
| `MIN_IRC_WIDTH` | 10 | width-shrink floor |
| `viterbiW` | `[0,6] step 0.5`, sweet spot 2 | 13 grid points, 4 bisection iterations |

In Lean, coverages are exact integers in units of `1/30000` (`COVERAGE_SCALE`), which is
divisible both by 10000 — the finest denominator in `GLYPH_COVERAGES` — and by 3, so
`(1 + cmax)/3` is exact.  Lumas are `0..255`, blends are stored pre-multiplied by the
coverage scale, and `viterbiW` is measured in luma units per byte
(`viterbiWeight k = 15000 * k` for `k` half steps).

## Derived constants

* `optimal_block_coverage r* = (1 + cmax)/3`.  For the measured medium shade
  `cmax = 0.273` this is `r* = 0.424333…` ≈ **0.4243**.
* `bandError cmax r = max(r - cmax, 1 - 2r)/2`; at `r*` both branches coincide and the
  error is `(1 - 2·cmax)/6 = 0.075667`, against `0.1105` at the measured block coverage
  `0.494` — an improvement of **31.5 %**.

## Compression order (deterministic)

1. **Glyph pruning.**  Keep the byte-gap Pareto frontier
   (`(|Δct| + |Δcb|)·contrast ≤ w·Δbytes ⇒ dominated`); if more than 14 glyphs survive,
   keep the 14 cheapest in the dominance ranking.
2. **Viterbi bisection** over `viterbiW ∈ [0,6] step 0.5`: probe the sweet spot `w = 2`
   first, then three halvings — four iterations, enough for the 13-point grid.
3. **Width shrink**: `pickFitStep` drops 4 columns at a time, never below
   `MIN_IRC_WIDTH = 10`.
4. **Palette downgrade**: `smart → xterm256 → 16`.
5. **Final guard**: width 10, `viterbiW = 6`, 16 colours, alphabet `[' ', '▀']`, and the
   notice `Image too detailed for 512B at 10 cols`.

## Theorems (all `sorry`-free)

| theorem | statement |
|---|---|
| `optimal_block_coverage` | `bandError` at `r* = (1+cmax)/3` is ≤ `bandError` at every other coverage |
| `bandError_at_optimum` | at `r*` the band error is `(1 - 2·cmax)/6` |
| `bandError_optimal_beats_measured` | `0.075667` vs `0.1105`, ≥ 31 % better |
| `dominatedByByteGap` | a dominated glyph never has a lower cell cost, on any cell |
| `pareto_optimal` | pruning to the frontier preserves the minimal cell cost of the full alphabet |
| `pareto_optimal_sweet_spot` | the same at `viterbiW ∈ [2,4]`, where the frontier is sandwiched between the `w = 2` and `w = 4` frontiers |
| `fits_upward_closed` | `{λ | bytes(λ) ≤ 512}` is upward closed because the byte count is antitone in `λ` |
| `bisect_fits`, `bisect_minimal`, `bisect_in_range` | the 4-iteration bisection returns the least feasible weight on the grid |
| `widthStep_ge_min`, `widthStep_fits_or_min` | width shrinking stops at a fitting width or at 10 |
| `fits_512` | the pipeline output is ≤ 512 bytes including the prefix reserve |
| `exists_optimal_alphabet_fitting_512` | `∃ alphabet K, ∀ cell, cellCost minimal ∧ Σ bytes ≤ 512` |
| `standardAlphabet_frontier_sizes` | 18 candidates prune to 15 glyphs at `w = 2` and 13 at `w = 4` (contrast 12) |
| `standardAlphabet_flat_cell_is_space` | a flat cell (contrast ≤ 2) prunes to the 1-byte space |

The encoder itself is abstracted by the `Encoder` structure: its byte count is bounded by
one colour code plus one glyph per cell, and is antitone in the Viterbi weight, monotone in
the width, and non-increasing under palette downgrade.  Nothing else about it is used, and
`boundEncoder` witnesses that these assumptions are satisfiable.
