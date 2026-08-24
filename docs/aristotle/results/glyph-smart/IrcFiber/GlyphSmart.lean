/-
# IrcFiber.GlyphSmart — the original sketch, superseded by `GlyphSmart`

The finished, `sorry`-free development lives in `frontend/wasm-img2irc/lean/GlyphSmart.lean`
(module `GlyphSmart`), next to the encoder it specifies.  This file keeps the original
sketch for the record and re-exports the finished results under the names used here.

The original statements are preserved verbatim in the block comment below, each annotated
with the reason it had to be restated.  In summary:

* `glyphBlend` had a precedence bug: `c * fg + (1000 - c) * bg / 1000` parses as
  `c * fg + ((1000 - c) * bg / 1000)`, so the first term is never divided by the scale.
  The corrected, division-free version is `GlyphSmart.blendScaled`.
* `optimal_block_coverage_is_minimizer` only restated the definition (`rfl`) and did not
  say that `r*` minimises anything.  The real statement — `bandError` at `r* = (1+cmax)/3`
  is `≤ bandError` at every other coverage — is `GlyphSmart.optimal_block_coverage`.
* `glyphDominatedByByteGap_sound` was `h → h`, i.e. vacuous.  The real soundness statement
  (a dominated glyph never has a lower cell cost, on any cell) is
  `GlyphSmart.dominatedByByteGap`.
* `fits_512` was false as stated: `width * bytes_per_cell ≤ 512 ∨ width = 10` fails for
  `width = 11`, `bytes_per_cell = 100`.  The true statement is about the output of the
  compression pipeline: `GlyphSmart.fits_512`.
* `pareto_optimal` was false as stated: `∀ alphabet, alphabet.length ≥ 2` fails for the
  empty alphabet.  The intended statement — pruning to the byte-gap Pareto frontier never
  raises the achievable cell cost — is `GlyphSmart.pareto_optimal`.
* `fits_upward_closed` was trivial (`h → h`, with `lam1`, `lam2` unused).  The real
  statement needs the byte count `B` and its antitonicity in `λ`:
  `GlyphSmart.fits_upward_closed`.
-/
import GlyphSmart

namespace IrcFiber

/-! ## Re-exports of the finished results -/

export GlyphSmart (IRC_HARD_LIMIT IRC_SAFE_PAYLOAD MIN_IRC_WIDTH GLYPH_BYTES_SPACE
  GLYPH_BYTES_HALF GLYPH_COVERAGES Glyph cellCost glyphDominatedByByteGap
  bandError optimalBlockCoverage paretoPrune compress)

/-- `optimal_block_coverage r* = (1 + cmax)/3 ≈ 0.4243` minimises the band error. -/
theorem optimal_block_coverage_is_minimizer (cmax : Int) (h : cmax % 3 = 0) (r : Int) :
    GlyphSmart.bandError cmax (GlyphSmart.optimalBlockCoverage cmax)
      ≤ GlyphSmart.bandError cmax r :=
  GlyphSmart.optimal_block_coverage cmax h r

/-- The optimal block coverage beats the measured `▒` coverage `0.494` by ≥ 31%
(exactly 31.5%). -/
theorem bandError_optimal_lt_measured :
    GlyphSmart.bandError GlyphSmart.SHADE_MEDIUM_COVERAGE
        (GlyphSmart.optimalBlockCoverage GlyphSmart.SHADE_MEDIUM_COVERAGE)
      < GlyphSmart.bandError GlyphSmart.SHADE_MEDIUM_COVERAGE
        GlyphSmart.MEASURED_BLOCK_COVERAGE := by
  decide

/-- A glyph flagged by `glyphDominatedByByteGap` is never better than the glyph that
dominates it — on any cell. -/
theorem glyphDominatedByByteGap_sound (w : Nat) (fg bg : Int) (g h : GlyphSmart.Glyph)
    (hdom : GlyphSmart.glyphDominatedByByteGap w fg bg g h = true) (tTop tBot : Int) :
    GlyphSmart.cellCost w g tTop tBot fg bg ≤ GlyphSmart.cellCost w h tTop tBot fg bg :=
  GlyphSmart.dominatedByByteGap w fg bg g h hdom tTop tBot

/-- The compression pipeline always emits a line of at most `IRC_HARD_LIMIT = 512` bytes. -/
theorem fits_512 (E : GlyphSmart.Encoder) (fg bg : Int) (c₀ : GlyphSmart.Config) :
    GlyphSmart.IRC_PREFIX_RESERVE + E.bytesOf (GlyphSmart.compress E fg bg c₀)
      ≤ GlyphSmart.IRC_HARD_LIMIT :=
  GlyphSmart.fits_512 E fg bg c₀

/-- Pruning to the byte-gap Pareto frontier never raises the achievable cell cost. -/
theorem pareto_optimal (w : Nat) (fg bg : Int) (A : List GlyphSmart.Glyph)
    (g : GlyphSmart.Glyph) (hg : g ∈ A) :
    ∃ g' ∈ GlyphSmart.paretoPrune w fg bg A, ∀ tTop tBot : Int,
      GlyphSmart.cellCost w g' tTop tBot fg bg ≤ GlyphSmart.cellCost w g tTop tBot fg bg :=
  GlyphSmart.pareto_optimal w fg bg A g hg

/-- The feasible set `{λ | longest(λ) ≤ 512}` is upward closed. -/
theorem fits_upward_closed (B : Nat → Nat) (hanti : ∀ i j : Nat, i ≤ j → B j ≤ B i)
    {lam1 lam2 : Nat} (h : lam1 ≤ lam2) (fits : B lam1 ≤ GlyphSmart.IRC_HARD_LIMIT) :
    B lam2 ≤ GlyphSmart.IRC_HARD_LIMIT :=
  GlyphSmart.fits_upward_closed B hanti h fits

end IrcFiber

/-
================================================================================
ORIGINAL SKETCH (kept verbatim; see the header for why each item was restated).
================================================================================

-- GlyphSmart — Smart detail glyph selection + 512B compression
-- IRC_HARD_LIMIT=512, IRC_SAFE_PAYLOAD=400, GLYPH_COVERAGES=[0,121/1000,254/1000,273/1000,4945/10000,5055/10000,727/1000,746/1000,879/1000,1]
-- GLYPH_BYTES_SPACE=1, GLYPH_BYTES_HALF=3, glyphCellCost at img2irc.ts:476, glyphDominatedByByteGap, LambdaPareto monotonicity, viterbiW ∈ [0,6] step 0.5
-- Goal: ∃ alphabet K, ∀ cell, cellCost minimal ∧ Σ bytes ≤ 512
import Std

def IRC_HARD_LIMIT : Nat := 512
def IRC_SAFE_PAYLOAD : Nat := 400
def MIN_IRC_WIDTH : Nat := 10
def GLYPH_BYTES_SPACE : Nat := 1
def GLYPH_BYTES_HALF : Nat := 3

def GLYPH_COVERAGES : List Nat := [0, 121, 254, 273, 4945, 5055, 727, 746, 879, 1000]

structure Glyph where
  ct : Nat
  cb : Nat
  bytes : Nat
  deriving DecidableEq, Repr

def glyphBlend (c fg bg : Nat) : Nat := c * fg + (1000 - c) * bg / 1000

def glyphCellCost (w ct cb bytes tTop tBot fg bg : Nat) : Nat :=
  (if tTop > glyphBlend ct fg bg then tTop - glyphBlend ct fg bg else glyphBlend ct fg bg - tTop)
  + (if tBot > glyphBlend cb fg bg then tBot - glyphBlend cb fg bg else glyphBlend cb fg bg - tBot)
  + w * bytes

def glyphBandError (cmax r : Nat) : Nat :=
  Nat.max (if r > cmax then r - cmax else 0) (if 1000 > 2 * r then (1000 - 2 * r) / 2 else 0) / 1

def glyphOptimalBlockCoverage (cmax : Nat) : Nat :=
  (1000 + cmax) / 3

def glyphDominatedByByteGap (w ct cb bytes ct2 cb2 bytes2 contrast : Nat) : Bool :=
  let deltaCt := if ct > ct2 then ct - ct2 else ct2 - ct
  let deltaCb := if cb > cb2 then cb - cb2 else cb2 - cb
  (deltaCt + deltaCb) * contrast <= w * (if bytes > bytes2 then bytes - bytes2 else 0)

theorem optimal_block_coverage_is_minimizer (cmax : Nat) (h : cmax < 1000) :
    glyphOptimalBlockCoverage cmax = (1000 + cmax) / 3 := by
  rfl

theorem bandError_optimal_lt_measured :
    glyphBandError 273 424 < glyphBandError 273 494 := by
  native_decide

theorem glyphDominatedByByteGap_sound (w ct cb bytes ct2 cb2 bytes2 contrast : Nat)
    (h : glyphDominatedByByteGap w ct cb bytes ct2 cb2 bytes2 contrast = true) :
    glyphDominatedByByteGap w ct cb bytes ct2 cb2 bytes2 contrast = true := by
  exact h

theorem fits_512 (width : Nat) (h : width >= MIN_IRC_WIDTH) (bytes_per_cell : Nat) :
    width * bytes_per_cell <= IRC_HARD_LIMIT ∨ width = MIN_IRC_WIDTH := by
  sorry

theorem pareto_optimal (w : Nat) (hw : w >= 2 ∧ w <= 4) :
    ∀ (alphabet : List Glyph), alphabet.length >= 2 := by
  sorry

theorem fits_upward_closed (lam1 lam2 : Nat) (h : lam1 < lam2) (fits : Nat) :
    fits <= IRC_HARD_LIMIT → fits <= IRC_HARD_LIMIT := by
  sorry
-/
