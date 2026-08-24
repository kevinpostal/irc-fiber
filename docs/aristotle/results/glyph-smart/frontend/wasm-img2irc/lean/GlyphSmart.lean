/-
# GlyphSmart — offline deterministic derivation for IRC Fiber *Smart detail* mode

This file is the machine-checked specification of the glyph-alphabet selection and
512-byte compression algorithm used by `frontend/src/lib/img2irc.ts` and mirrored,
as a pure function, in `frontend/src/lib/aristotleGlyphs.ts`.

Hard constants of the encoder (reproduced literally):

* `IRC_HARD_LIMIT=512`   (frontend/src/lib/img2irc.ts:154) — RFC 2812 hard limit, 512 bytes
  including prefix and CRLF.
* `IRC_SAFE_PAYLOAD=400` (frontend/src/lib/img2irc.ts:157) — leaves ~112 bytes for the
  PRIVMSG prefix / tags.
* `GLYPH_COVERAGES=[0,121/1000,254/1000,273/1000,4945/10000,5055/10000,727/1000,746/1000,879/1000,1]`
  (img2irc.ts:480).
* `GLYPH_BYTES_SPACE=1` (img2irc.ts:561) — a space costs 1 byte.
* `GLYPH_BYTES_HALF=3`  (img2irc.ts:561) — a half block costs 3 bytes.
* `glyphCellCost` (img2irc.ts:476): `|tTop - blend(ct,fg,bg)| + |tBot - blend(cb,fg,bg)| + w*bytes`.
* `glyphDominatedByByteGap` (img2irc.ts:482-488): `(|Δct|+|Δcb|)*contrast ≤ w*Δbytes → dominated`.
* `viterbiW ∈ [0,6] step 0.5` — bisection range (4 iterations, start at the `w = 2` sweet spot).
* `MIN_IRC_WIDTH=10`.

## Arithmetic conventions

Everything is exact integer arithmetic; no floating point and no `Real`s appear.

* A *coverage* (the ink fraction of the top or bottom half-cell of a glyph) is an integer in
  units of `1/COVERAGE_SCALE` with `COVERAGE_SCALE = 30000`.  30000 is divisible by 10000
  (the finest denominator occurring in `GLYPH_COVERAGES`) and by 3 (needed for the exact
  optimal block coverage `(1+cmax)/3`), so every quantity below is an exact integer.
* A *luma* is an integer `0..255`.  A blend is stored pre-multiplied by `COVERAGE_SCALE`
  (`blendScaled`), so blending is division-free and exact.
* `viterbiW` is expressed in luma units per byte; on the `step 0.5` grid it is given by an
  integer number of half steps `k ∈ [0,12]`, and the weight used in the cost function is
  `viterbiWeight k = 15000 * k` scaled-luma units per byte.

## Contents

1. Constants.
2. Blending, `cellCost`, and the byte-gap dominance test (`dominatedByByteGap`).
3. Band error and the optimal block coverage `r* = (1 + cmax)/3`.
4. Pareto pruning of the glyph alphabet (`pareto_optimal`).
5. Viterbi-weight bisection (`fits_upward_closed`, `bisect_fits`, `bisect_minimal`).
6. The deterministic compression pipeline and `fits_512`.
7. The concrete Smart alphabet and the top-level existence theorem.
-/
import Std

namespace GlyphSmart

/-! ## 1. Hard constants -/

/-- RFC 2812 hard limit: 512 bytes for a whole IRC line, prefix and CRLF included. -/
def IRC_HARD_LIMIT : Nat := 512

/-- Payload budget: leaves `512 - 400 = 112` bytes for the PRIVMSG prefix / tags. -/
def IRC_SAFE_PAYLOAD : Nat := 400

/-- Bytes reserved for the PRIVMSG prefix, tags and CRLF. -/
def IRC_PREFIX_RESERVE : Nat := IRC_HARD_LIMIT - IRC_SAFE_PAYLOAD

theorem irc_prefix_reserve_eq : IRC_PREFIX_RESERVE = 112 := rfl

/-- The narrowest picture the width-shrink step will ever produce. -/
def MIN_IRC_WIDTH : Nat := 10

/-- `pickFitStep` shrinks the width by 4 columns at a time. -/
def WIDTH_STEP : Nat := 4

/-- A space (U+0020) costs one byte. -/
def GLYPH_BYTES_SPACE : Nat := 1

/-- A half block (U+2580 …) is three bytes of UTF-8. -/
def GLYPH_BYTES_HALF : Nat := 3

/-- Smart detail asks for an alphabet of `12..18` glyphs; pruning targets 14. -/
def MIN_ALPHABET : Nat := 12
def PRUNE_TARGET : Nat := 14
def MAX_ALPHABET : Nat := 18

/-- Coverages are integers in units of `1/COVERAGE_SCALE`. -/
def COVERAGE_SCALE : Int := 30000

/-- `GLYPH_COVERAGES=[0,121/1000,254/1000,273/1000,4945/10000,5055/10000,727/1000,746/1000,879/1000,1]`
scaled by `COVERAGE_SCALE = 30000`. -/
def GLYPH_COVERAGES : List Int :=
  [0, 3630, 7620, 8190, 14835, 16515, 21810, 22380, 26370, 30000]

theorem glyph_coverages_length : GLYPH_COVERAGES.length = 10 := rfl

/-- Every listed coverage lies in `[0,1]` and is a multiple of 3 (so `(1+c)/3` is exact). -/
theorem glyph_coverages_wf :
    ∀ c ∈ GLYPH_COVERAGES, 0 ≤ c ∧ c ≤ COVERAGE_SCALE ∧ c % 3 = 0 := by decide

/-- `viterbiW ∈ [0,6] step 0.5`, encoded as `k` half steps, `k ∈ [0,12]`. -/
def VITERBI_MAX_HALF_STEPS : Nat := 12

/-- The `w = 2` sweet spot, in half steps. -/
def VITERBI_SWEET_SPOT : Nat := 4

/-- Weight of one byte in the cell cost, in scaled-luma units, for `k` half steps of
`viterbiW` (i.e. `viterbiW = k/2`). -/
def viterbiWeight (k : Nat) : Nat := 15000 * k

theorem viterbi_sweet_spot_is_two : viterbiWeight VITERBI_SWEET_SPOT = 2 * 30000 := rfl

/-! ## 2. Glyphs, blending, cell cost, byte-gap dominance -/

/-- A glyph: coverage of its top half, coverage of its bottom half, and its UTF-8 size. -/
structure Glyph where
  ct : Int
  cb : Int
  bytes : Nat
deriving DecidableEq, Repr

/-- `blend(c,fg,bg) = bg + c*(fg-bg)`, pre-multiplied by `COVERAGE_SCALE` so that it is
an exact integer. -/
def blendScaled (c fg bg : Int) : Int := COVERAGE_SCALE * bg + c * (fg - bg)

/-- Absolute difference of two scaled lumas. -/
def adist (a b : Int) : Nat := (a - b).natAbs

/-- `contrast = |fg - bg|`. -/
def contrast (fg bg : Int) : Nat := (fg - bg).natAbs

/-- `glyphCellCost` (img2irc.ts:476):
`|tTop - blend(ct,fg,bg)| + |tBot - blend(cb,fg,bg)| + w*bytes`.
`tTop`, `tBot` are the two target lumas of the cell, scaled by `COVERAGE_SCALE`;
`w` is `viterbiWeight k`. -/
def cellCost (w : Nat) (g : Glyph) (tTop tBot fg bg : Int) : Nat :=
  adist tTop (blendScaled g.ct fg bg) + adist tBot (blendScaled g.cb fg bg) + w * g.bytes

/-- `glyphDominatedByByteGap` (img2irc.ts:482-488): the cheap glyph `g` dominates the
expensive glyph `h` when the coverage error it can possibly add, `(|Δct|+|Δcb|)*contrast`,
is paid for by the bytes it saves, `w*Δbytes`. -/
def glyphDominatedByByteGap (w : Nat) (fg bg : Int) (g h : Glyph) : Bool :=
  decide (g.bytes < h.bytes) &&
    decide (((g.ct - h.ct).natAbs + (g.cb - h.cb).natAbs) * contrast fg bg
              ≤ w * (h.bytes - g.bytes))

/-- Blending is affine in the coverage. -/
theorem blendScaled_sub (c₁ c₂ fg bg : Int) :
    blendScaled c₁ fg bg - blendScaled c₂ fg bg = (c₁ - c₂) * (fg - bg) := by
  unfold blendScaled; grind

/-- Blending is exactly `contrast`-Lipschitz in the coverage. -/
theorem blendScaled_dist (c₁ c₂ fg bg : Int) :
    (blendScaled c₁ fg bg - blendScaled c₂ fg bg).natAbs
      = (c₁ - c₂).natAbs * contrast fg bg := by
  rw [blendScaled_sub, Int.natAbs_mul]; rfl

/-- **Byte-gap dominance is sound.**  If `glyphDominatedByByteGap w fg bg g h` holds then
the cheaper glyph `g` is at least as good as `h` on *every* cell of the image: its cell cost
is never larger, whatever the two target lumas are.  Hence `h` may be dropped from the
alphabet without ever increasing the total cost. -/
theorem dominatedByByteGap (w : Nat) (fg bg : Int) (g h : Glyph)
    (hdom : glyphDominatedByByteGap w fg bg g h = true) (tTop tBot : Int) :
    cellCost w g tTop tBot fg bg ≤ cellCost w h tTop tBot fg bg := by
  unfold glyphDominatedByByteGap at hdom
  simp only [Bool.and_eq_true, decide_eq_true_eq] at hdom
  obtain ⟨hb, hgap⟩ := hdom
  have htop : adist tTop (blendScaled g.ct fg bg)
      ≤ adist tTop (blendScaled h.ct fg bg) + (g.ct - h.ct).natAbs * contrast fg bg := by
    have e := blendScaled_dist h.ct g.ct fg bg
    have e2 : (h.ct - g.ct).natAbs = (g.ct - h.ct).natAbs := by omega
    rw [e2] at e
    unfold adist
    omega
  have hbot : adist tBot (blendScaled g.cb fg bg)
      ≤ adist tBot (blendScaled h.cb fg bg) + (g.cb - h.cb).natAbs * contrast fg bg := by
    have e := blendScaled_dist h.cb g.cb fg bg
    have e2 : (h.cb - g.cb).natAbs = (g.cb - h.cb).natAbs := by omega
    rw [e2] at e
    unfold adist
    omega
  have hsplit : ((g.ct - h.ct).natAbs + (g.cb - h.cb).natAbs) * contrast fg bg
      = (g.ct - h.ct).natAbs * contrast fg bg + (g.cb - h.cb).natAbs * contrast fg bg :=
    Nat.add_mul _ _ _
  have hw : w * g.bytes + ((g.ct - h.ct).natAbs * contrast fg bg
              + (g.cb - h.cb).natAbs * contrast fg bg) ≤ w * h.bytes := by
    have : w * (h.bytes - g.bytes) + w * g.bytes = w * h.bytes := by
      rw [← Nat.mul_add]
      congr 1
      omega
    omega
  unfold cellCost
  omega

/-! ## 3. Band error and the optimal block coverage -/

/-
A "block" glyph of coverage `r` used against a background of maximal shade coverage `cmax`
has to cover the luma band it is responsible for.  Its worst-case band error is

  `bandError cmax r = max (r - cmax, 1 - 2r) / 2`,

the first branch being the gap it leaves above the densest shade and the second the gap it
leaves below.  The first branch increases in `r`, the second decreases, so the maximum is
minimised where they cross, at

  `r* = (1 + cmax)/3`.

For the measured medium shade `▒`, `cmax = 273/1000`, this gives `r* = 1273/3000 ≈ 0.4243`.
-/

/-- Twice the worst-case band error, in units of `1/COVERAGE_SCALE`; `bandError` itself is
this halved. -/
def bandErrorDoubled (cmax r : Int) : Int := max (r - cmax) (COVERAGE_SCALE - 2 * r)

/-- `bandError cmax r = max(r - cmax, 1 - 2r)/2`, in units of `1/COVERAGE_SCALE`. -/
def bandError (cmax r : Int) : Int := bandErrorDoubled cmax r / 2

/-- `optimal_block_coverage r* = (1 + cmax)/3 ≈ 0.4243`. -/
def optimalBlockCoverage (cmax : Int) : Int := (COVERAGE_SCALE + cmax) / 3

/-- The optimal block coverage really solves `3 r* = 1 + cmax` (exactly, whenever `cmax`
is a multiple of 3 in scaled units — which every entry of `GLYPH_COVERAGES` is). -/
theorem optimal_block_coverage_exact (cmax : Int) (h : cmax % 3 = 0) :
    3 * optimalBlockCoverage cmax = COVERAGE_SCALE + cmax := by
  unfold optimalBlockCoverage COVERAGE_SCALE
  omega

/-- `optimal_block_coverage r* = (1 + cmax)/3 ≈ 0.4243` for the measured `cmax = 0.273`:
`r* = 12730/30000 = 0.424333…`. -/
theorem optimal_block_coverage_value : optimalBlockCoverage 8190 = 12730 := by decide

/-- **The optimal block coverage minimises the band error.** No coverage `r` whatsoever
does better than `r* = (1+cmax)/3`. -/
theorem optimal_block_coverage (cmax : Int) (h : cmax % 3 = 0) (r : Int) :
    bandError cmax (optimalBlockCoverage cmax) ≤ bandError cmax r := by
  unfold bandError bandErrorDoubled optimalBlockCoverage COVERAGE_SCALE
  omega

/-- At the optimum both branches of the max coincide: the band error is `(1 - 2 cmax)/6`. -/
theorem bandError_at_optimum (cmax : Int) (h : cmax % 3 = 0) :
    3 * bandErrorDoubled cmax (optimalBlockCoverage cmax) = COVERAGE_SCALE - 2 * cmax := by
  unfold bandErrorDoubled optimalBlockCoverage COVERAGE_SCALE at *
  omega

/-- Coverage of the medium shade `▒`, `0.273`. -/
def SHADE_MEDIUM_COVERAGE : Int := 8190

/-- The block coverage actually measured for `▒` in the encoder, `0.494`. -/
def MEASURED_BLOCK_COVERAGE : Int := 14820

/-- **`bandError` quantifies the improvement of `r*` over the measured `▒` coverage.**
`bandError` at `r* = 0.4243…` is `2270/30000 = 0.075667`, against `3315/30000 = 0.1105`
for the measured `0.494`: an improvement of `1045/3315 = 31.52%`, i.e. ≥ 31%. -/
theorem bandError_optimal_beats_measured :
    bandError SHADE_MEDIUM_COVERAGE (optimalBlockCoverage SHADE_MEDIUM_COVERAGE) = 2270 ∧
    bandError SHADE_MEDIUM_COVERAGE MEASURED_BLOCK_COVERAGE = 3315 ∧
    100 * (3315 - 2270) ≥ 31 * 3315 := by
  refine ⟨by decide, by decide, by decide⟩

/-! ## 4. Pareto pruning of the alphabet -/

/-- The byte-gap Pareto frontier of an alphabet: keep exactly the glyphs that no other
glyph of the alphabet dominates.  This is step 1 of the compression order. -/
def paretoPrune (w : Nat) (fg bg : Int) (A : List Glyph) : List Glyph :=
  A.filter (fun g => !A.any (fun g' => glyphDominatedByByteGap w fg bg g' g))

theorem paretoPrune_sublist (w : Nat) (fg bg : Int) (A : List Glyph) :
    ∀ g ∈ paretoPrune w fg bg A, g ∈ A := fun _ hg => (List.mem_filter.mp hg).1

theorem paretoPrune_length_le (w : Nat) (fg bg : Int) (A : List Glyph) :
    (paretoPrune w fg bg A).length ≤ A.length := List.length_filter_le _ _

/-- Auxiliary strong induction on the byte size of the glyph. -/
theorem paretoPrune_covers_aux (w : Nat) (fg bg : Int) (A : List Glyph) :
    ∀ n : Nat, ∀ g : Glyph, g.bytes = n → g ∈ A →
      ∃ g' ∈ paretoPrune w fg bg A, ∀ tTop tBot : Int,
        cellCost w g' tTop tBot fg bg ≤ cellCost w g tTop tBot fg bg := by
  intro n
  induction n using Nat.strongRecOn with
  | _ n ih =>
    intro g hgn hgA
    by_cases hdom : A.any (fun g' => glyphDominatedByByteGap w fg bg g' g) = true
    · obtain ⟨g', hg'A, hg'⟩ := List.any_eq_true.mp hdom
      have hlt : g'.bytes < g.bytes := by
        unfold glyphDominatedByByteGap at hg'
        simp only [Bool.and_eq_true, decide_eq_true_eq] at hg'
        exact hg'.1
      obtain ⟨g'', hg''mem, hg''le⟩ := ih g'.bytes (by omega) g' rfl hg'A
      exact ⟨g'', hg''mem, fun tTop tBot =>
        Nat.le_trans (hg''le tTop tBot) (dominatedByByteGap w fg bg g' g hg' tTop tBot)⟩
    · refine ⟨g, List.mem_filter.mpr ⟨hgA, ?_⟩, fun _ _ => Nat.le_refl _⟩
      simp only [Bool.not_eq_true] at hdom ⊢
      simp [hdom]

/-- **`pareto_optimal`.**  Pruning the alphabet down to its byte-gap Pareto frontier never
costs anything: for every glyph `g` of the original alphabet there is a surviving glyph `g'`
that is at least as good on *every* cell.  Consequently no alphabet outside the frontier —
in particular no alphabet using more bytes — can achieve a lower cell cost, and the minimal
cell cost over the pruned alphabet equals the minimal cell cost over the full one. -/
theorem pareto_optimal (w : Nat) (fg bg : Int) (A : List Glyph) (g : Glyph) (hg : g ∈ A) :
    ∃ g' ∈ paretoPrune w fg bg A, ∀ tTop tBot : Int,
      cellCost w g' tTop tBot fg bg ≤ cellCost w g tTop tBot fg bg :=
  paretoPrune_covers_aux w fg bg A g.bytes g rfl hg

/-- The pruned alphabet is never empty when the original is not. -/
theorem paretoPrune_ne_nil (w : Nat) (fg bg : Int) (A : List Glyph) (g : Glyph) (hg : g ∈ A) :
    paretoPrune w fg bg A ≠ [] := by
  obtain ⟨g', hg', _⟩ := pareto_optimal w fg bg A g hg
  intro h
  rw [h] at hg'
  exact (List.not_mem_nil hg')

/-! ## 5. Viterbi-weight bisection -/

/-- **`fits_upward_closed`.**  The feasible set `{λ | longest(λ) ≤ 512}` is upward closed,
because the byte count `B` is antitone in `λ` (a larger Viterbi weight buys cheaper glyphs).
This is what makes bisection over the weight grid correct. -/
theorem fits_upward_closed (B : Nat → Nat) (hanti : ∀ i j : Nat, i ≤ j → B j ≤ B i)
    {k₁ k₂ : Nat} (hk : k₁ ≤ k₂) (h : B k₁ ≤ IRC_HARD_LIMIT) : B k₂ ≤ IRC_HARD_LIMIT :=
  Nat.le_trans (hanti k₁ k₂ hk) h

/-- The same upward closure for an arbitrary budget, e.g. `IRC_SAFE_PAYLOAD`. -/
theorem fits_upward_closed_of_budget (B : Nat → Nat) (hanti : ∀ i j : Nat, i ≤ j → B j ≤ B i)
    (L : Nat) {k₁ k₂ : Nat} (hk : k₁ ≤ k₂) (h : B k₁ ≤ L) : B k₂ ≤ L :=
  Nat.le_trans (hanti k₁ k₂ hk) h

/-- One bisection sweep on the half-step grid `[lo, hi]`, maintaining the invariants
`B hi` fits and nothing below `lo` fits. -/
def bisectAux (B : Nat → Nat) : Nat → Nat → Nat → Nat
  | 0, _, hi => hi
  | fuel + 1, lo, hi =>
      if hi ≤ lo then hi
      else
        let mid := (lo + hi) / 2
        if B mid ≤ IRC_SAFE_PAYLOAD then bisectAux B fuel lo mid else bisectAux B fuel (mid + 1) hi

/-- Step 2 of the compression order: bisection of `viterbiW ∈ [0,6] step 0.5`, i.e. of the
half-step index `k ∈ [0,12]`.  The first probe is the sweet spot `w = 2` (`k = 4`); three
further bisection steps then pin down the least feasible weight — four iterations in all. -/
def bisectViterbi (B : Nat → Nat) : Nat :=
  if B VITERBI_SWEET_SPOT ≤ IRC_SAFE_PAYLOAD then bisectAux B 3 0 VITERBI_SWEET_SPOT
  else bisectAux B 3 (VITERBI_SWEET_SPOT + 1) VITERBI_MAX_HALF_STEPS

/-- Correctness of one bisection sweep: it returns a feasible weight, it is the least
feasible one, and it stays inside the bracket. -/
theorem bisectAux_spec (B : Nat → Nat) (hanti : ∀ i j : Nat, i ≤ j → B j ≤ B i) :
    ∀ fuel lo hi : Nat, hi - lo ≤ 2 ^ fuel - 1 → lo ≤ hi → B hi ≤ IRC_SAFE_PAYLOAD →
      (∀ k, k < lo → ¬ B k ≤ IRC_SAFE_PAYLOAD) →
      B (bisectAux B fuel lo hi) ≤ IRC_SAFE_PAYLOAD ∧
        (∀ k, k < bisectAux B fuel lo hi → ¬ B k ≤ IRC_SAFE_PAYLOAD) ∧
        lo ≤ bisectAux B fuel lo hi ∧ bisectAux B fuel lo hi ≤ hi := by
  intro fuel
  induction fuel with
  | zero =>
    intro lo hi hd hlo hfit hbelow
    have : hi = lo := by simp at hd; omega
    subst this
    exact ⟨hfit, hbelow, Nat.le_refl _, Nat.le_refl _⟩
  | succ fuel ih =>
    intro lo hi hd hlo hfit hbelow
    rw [bisectAux]
    by_cases hle : hi ≤ lo
    · have hEq : hi = lo := by omega
      subst hEq
      rw [if_pos (Nat.le_refl hi)]
      exact ⟨hfit, hbelow, Nat.le_refl _, Nat.le_refl _⟩
    · rw [if_neg hle]
      have hpow : 1 ≤ 2 ^ fuel := Nat.one_le_two_pow
      have hpow2 : 2 ^ (fuel + 1) = 2 * 2 ^ fuel := by rw [Nat.pow_succ]; omega
      rw [hpow2] at hd
      have hmid1 : lo ≤ (lo + hi) / 2 := by omega
      have hmid2 : (lo + hi) / 2 < hi := by omega
      by_cases hmf : B ((lo + hi) / 2) ≤ IRC_SAFE_PAYLOAD
      · rw [if_pos hmf]
        obtain ⟨h1, h2, h3, h4⟩ := ih lo ((lo + hi) / 2) (by omega) hmid1 hmf hbelow
        exact ⟨h1, h2, h3, by omega⟩
      · rw [if_neg hmf]
        obtain ⟨h1, h2, h3, h4⟩ := ih ((lo + hi) / 2 + 1) hi (by omega) (by omega) hfit
          (by intro k hk hkfit
              exact hmf (fits_upward_closed_of_budget B hanti IRC_SAFE_PAYLOAD (by omega) hkfit))
        exact ⟨h1, h2, by omega, h4⟩

/-- The bisection returns a feasible Viterbi weight, provided the largest weight `w = 6`
is feasible at all. -/
theorem bisect_fits (B : Nat → Nat) (hanti : ∀ i j : Nat, i ≤ j → B j ≤ B i)
    (hmax : B VITERBI_MAX_HALF_STEPS ≤ IRC_SAFE_PAYLOAD) :
    B (bisectViterbi B) ≤ IRC_SAFE_PAYLOAD := by
  unfold bisectViterbi
  by_cases h : B VITERBI_SWEET_SPOT ≤ IRC_SAFE_PAYLOAD
  · simp only [h, if_true]
    exact (bisectAux_spec B hanti 3 0 VITERBI_SWEET_SPOT (by decide) (by decide) h
      (by intro k hk; omega)).1
  · simp only [h, if_false]
    refine (bisectAux_spec B hanti 3 (VITERBI_SWEET_SPOT + 1) VITERBI_MAX_HALF_STEPS
      (by decide) (by decide) hmax ?_).1
    intro k hk hkfit
    exact h (fits_upward_closed_of_budget B hanti IRC_SAFE_PAYLOAD
      (by unfold VITERBI_SWEET_SPOT at *; omega) hkfit)

/-- The bisection returns the *least* feasible Viterbi weight on the grid. -/
theorem bisect_minimal (B : Nat → Nat) (hanti : ∀ i j : Nat, i ≤ j → B j ≤ B i)
    (hmax : B VITERBI_MAX_HALF_STEPS ≤ IRC_SAFE_PAYLOAD) :
    ∀ k, k < bisectViterbi B → ¬ B k ≤ IRC_SAFE_PAYLOAD := by
  unfold bisectViterbi
  by_cases h : B VITERBI_SWEET_SPOT ≤ IRC_SAFE_PAYLOAD
  · simp only [h, if_true]
    exact (bisectAux_spec B hanti 3 0 VITERBI_SWEET_SPOT (by decide) (by decide) h
      (by intro k hk; omega)).2.1
  · simp only [h, if_false]
    refine (bisectAux_spec B hanti 3 (VITERBI_SWEET_SPOT + 1) VITERBI_MAX_HALF_STEPS
      (by decide) (by decide) hmax ?_).2.1
    intro k hk hkfit
    exact h (fits_upward_closed_of_budget B hanti IRC_SAFE_PAYLOAD
      (by unfold VITERBI_SWEET_SPOT at *; omega) hkfit)

/-- The bisection never leaves the grid `[0,12]`, i.e. `viterbiW ∈ [0,6]`. -/
theorem bisect_in_range (B : Nat → Nat) (hanti : ∀ i j : Nat, i ≤ j → B j ≤ B i)
    (hmax : B VITERBI_MAX_HALF_STEPS ≤ IRC_SAFE_PAYLOAD) :
    bisectViterbi B ≤ VITERBI_MAX_HALF_STEPS := by
  unfold bisectViterbi
  by_cases h : B VITERBI_SWEET_SPOT ≤ IRC_SAFE_PAYLOAD
  · simp only [h, if_true]
    have := (bisectAux_spec B hanti 3 0 VITERBI_SWEET_SPOT (by decide) (by decide) h
      (by intro k hk; omega)).2.2.2
    unfold VITERBI_SWEET_SPOT VITERBI_MAX_HALF_STEPS at *
    omega
  · simp only [h, if_false]
    refine Nat.le_trans (bisectAux_spec B hanti 3 (VITERBI_SWEET_SPOT + 1)
      VITERBI_MAX_HALF_STEPS (by decide) (by decide) hmax ?_).2.2.2 (Nat.le_refl _)
    intro k hk hkfit
    exact h (fits_upward_closed_of_budget B hanti IRC_SAFE_PAYLOAD
      (by unfold VITERBI_SWEET_SPOT at *; omega) hkfit)

/-! ## 6. The deterministic compression pipeline -/

/-- The three colour modes the encoder can fall back through. -/
inductive Palette where
  | smart
  | xterm256
  | ansi16
deriving DecidableEq, Repr

/-- Upper bound on the bytes a single cell spends on colour codes in each mode. -/
def paletteBytes : Palette → Nat
  | .smart => 12
  | .xterm256 => 9
  | .ansi16 => 6

/-- Step 4 of the compression order: `smart → xterm256 → 16`. -/
def downgradePalette : Palette → Palette
  | .smart => .xterm256
  | .xterm256 => .ansi16
  | .ansi16 => .ansi16

theorem downgradePalette_le (p : Palette) : paletteBytes (downgradePalette p) ≤ paletteBytes p := by
  cases p <;> decide

/-- The most expensive glyph of an alphabet. -/
def maxGlyphBytes (A : List Glyph) : Nat := A.foldl (fun a g => max a g.bytes) 0

/-- A rendering configuration: width in cells, Viterbi weight in half steps, colour mode,
glyph alphabet. -/
structure Config where
  width : Nat
  wHalf : Nat
  palette : Palette
  alphabet : List Glyph
deriving Repr

/-- Worst-case payload of one rendered line: every cell pays for a colour code and its
glyph. -/
def payloadBound (c : Config) : Nat := c.width * (paletteBytes c.palette + maxGlyphBytes c.alphabet)

/-- The minimal alphabet `[' ', '▀']`: 1 byte for the space, 3 for the half block. -/
def minimalAlphabet : List Glyph :=
  [{ ct := 0, cb := 0, bytes := GLYPH_BYTES_SPACE },
   { ct := COVERAGE_SCALE, cb := 0, bytes := GLYPH_BYTES_HALF }]

/-- Step 5, the final guard: width 10, `viterbiW = 6`, 16 colours, minimal glyphs. -/
def fallbackConfig : Config :=
  { width := MIN_IRC_WIDTH, wHalf := VITERBI_MAX_HALF_STEPS, palette := .ansi16,
    alphabet := minimalAlphabet }

/-- The message emitted when even the fallback picture is unusable. -/
def TOO_DETAILED_MESSAGE : String := "Image too detailed for 512B at 10 cols"

/-- The fallback line costs at most `10 * (6 + 3) = 90` payload bytes. -/
theorem fallback_payload_bound : payloadBound fallbackConfig = 90 := by decide

theorem fallback_fits : payloadBound fallbackConfig ≤ IRC_SAFE_PAYLOAD := by decide

/-- What the actual (Viterbi + run-length + colour-run) encoder guarantees.  These four
monotonicity facts are exactly the properties the compression order relies on; nothing else
about the encoder is used. -/
structure Encoder where
  /-- Payload bytes of the line the encoder produces for a configuration. -/
  bytesOf : Config → Nat
  /-- A cell never costs more than one colour code plus its glyph. -/
  cellBound : ∀ c, bytesOf c ≤ payloadBound c
  /-- `B` is antitone in the Viterbi weight: a bigger byte penalty buys cheaper glyphs. -/
  wAntitone : ∀ (c : Config) (k₁ k₂ : Nat), k₁ ≤ k₂ →
    bytesOf { c with wHalf := k₂ } ≤ bytesOf { c with wHalf := k₁ }
  /-- Fewer columns never cost more bytes. -/
  widthMono : ∀ (c : Config) (w₁ w₂ : Nat), w₁ ≤ w₂ →
    bytesOf { c with width := w₁ } ≤ bytesOf { c with width := w₂ }
  /-- Downgrading the palette never costs more bytes. -/
  paletteMono : ∀ c : Config, bytesOf { c with palette := downgradePalette c.palette } ≤ bytesOf c

/-- The specification is not vacuous: the worst-case bound `payloadBound` is itself a legal
encoder. -/
def boundEncoder : Encoder where
  bytesOf := payloadBound
  cellBound _ := Nat.le_refl _
  wAntitone _ _ _ _ := Nat.le_refl _
  widthMono _ _ _ h := Nat.mul_le_mul_right _ h
  paletteMono _ := Nat.mul_le_mul_left _ (Nat.add_le_add_right (downgradePalette_le _) _)

/-- **Step 1 — glyph pruning.**  If the alphabet has more than 14 glyphs, drop the ones the
byte-gap dominance order rejects (they cost more bytes for no gain), and keep at most 14. -/
def pruneStep (fg bg : Int) (c : Config) : Config :=
  if PRUNE_TARGET < c.alphabet.length then
    { c with alphabet := (paretoPrune (viterbiWeight c.wHalf) fg bg c.alphabet).take PRUNE_TARGET }
  else c

theorem pruneStep_length_le (fg bg : Int) (c : Config) :
    (pruneStep fg bg c).alphabet.length ≤ max PRUNE_TARGET c.alphabet.length := by
  unfold pruneStep
  split
  · simp only [List.length_take]
    omega
  · omega

/-- **Step 2 — Viterbi bisection** over `viterbiW ∈ [0,6] step 0.5`, starting at the sweet
spot `w = 2`, four iterations. -/
def bisectStep (E : Encoder) (c : Config) : Config :=
  { c with wHalf := bisectViterbi (fun k => E.bytesOf { c with wHalf := k }) }

/-- **Step 3 — width shrink**: `pickFitStep` removes 4 columns at a time, never going below
`MIN_IRC_WIDTH = 10`. -/
def shrinkWidth (E : Encoder) : Nat → Config → Config
  | 0, c => c
  | fuel + 1, c =>
      if E.bytesOf c ≤ IRC_SAFE_PAYLOAD then c
      else if c.width < MIN_IRC_WIDTH + WIDTH_STEP then { c with width := MIN_IRC_WIDTH }
      else shrinkWidth E fuel { c with width := c.width - WIDTH_STEP }

def widthStep (E : Encoder) (c : Config) : Config := shrinkWidth E c.width c

theorem shrinkWidth_ge_min (E : Encoder) :
    ∀ (fuel : Nat) (c : Config), MIN_IRC_WIDTH ≤ c.width →
      MIN_IRC_WIDTH ≤ (shrinkWidth E fuel c).width := by
  intro fuel
  induction fuel with
  | zero => intro c h; exact h
  | succ fuel ih =>
    intro c h
    rw [shrinkWidth]
    split
    · exact h
    · split
      · exact Nat.le_refl _
      · rename_i hge
        have hw : ({ c with width := c.width - WIDTH_STEP } : Config).width
            = c.width - WIDTH_STEP := rfl
        refine ih _ ?_
        rw [hw]
        simp only [WIDTH_STEP, MIN_IRC_WIDTH] at h hge ⊢
        omega

/-- Width shrinking terminates either with a line that fits or at the minimum width. -/
theorem shrinkWidth_fits_or_min (E : Encoder) :
    ∀ (fuel : Nat) (c : Config), MIN_IRC_WIDTH ≤ c.width →
      c.width ≤ MIN_IRC_WIDTH + WIDTH_STEP * fuel →
      E.bytesOf (shrinkWidth E fuel c) ≤ IRC_SAFE_PAYLOAD ∨
        (shrinkWidth E fuel c).width = MIN_IRC_WIDTH := by
  intro fuel
  induction fuel with
  | zero =>
    intro c h1 h2
    rw [shrinkWidth]
    right
    omega
  | succ fuel ih =>
    intro c h1 h2
    rw [shrinkWidth]
    split
    · exact Or.inl (by assumption)
    · split
      · exact Or.inr rfl
      · rename_i hge
        have hw : ({ c with width := c.width - WIDTH_STEP } : Config).width
            = c.width - WIDTH_STEP := rfl
        refine ih _ ?_ ?_ <;> rw [hw] <;>
          simp only [WIDTH_STEP, MIN_IRC_WIDTH] at h1 h2 hge ⊢ <;> omega

theorem widthStep_ge_min (E : Encoder) (c : Config) (h : MIN_IRC_WIDTH ≤ c.width) :
    MIN_IRC_WIDTH ≤ (widthStep E c).width := shrinkWidth_ge_min E c.width c h

theorem widthStep_fits_or_min (E : Encoder) (c : Config) (h : MIN_IRC_WIDTH ≤ c.width) :
    E.bytesOf (widthStep E c) ≤ IRC_SAFE_PAYLOAD ∨ (widthStep E c).width = MIN_IRC_WIDTH :=
  shrinkWidth_fits_or_min E c.width c h (by unfold WIDTH_STEP MIN_IRC_WIDTH; omega)

/-- **Step 4 — palette downgrade**: `smart → xterm256 → 16`. -/
def paletteStep (E : Encoder) (c : Config) : Config :=
  if E.bytesOf c ≤ IRC_SAFE_PAYLOAD then c
  else if E.bytesOf { c with palette := downgradePalette c.palette } ≤ IRC_SAFE_PAYLOAD then
    { c with palette := downgradePalette c.palette }
  else { c with palette := downgradePalette (downgradePalette c.palette) }

theorem paletteStep_ansi16 (E : Encoder) (c : Config) (h : ¬ E.bytesOf c ≤ IRC_SAFE_PAYLOAD)
    (h₁ : ¬ E.bytesOf { c with palette := downgradePalette c.palette } ≤ IRC_SAFE_PAYLOAD) :
    (paletteStep E c).palette = .ansi16 := by
  unfold paletteStep
  rw [if_neg h]
  simp only [h₁, if_false]
  cases c.palette <;> rfl

/-- **The whole deterministic, offline compression order.**
1. glyph pruning, 2. Viterbi bisection, 3. width shrink, 4. palette downgrade,
5. final guard. -/
def compress (E : Encoder) (fg bg : Int) (c₀ : Config) : Config :=
  if E.bytesOf (paletteStep E (widthStep E (bisectStep E (pruneStep fg bg c₀))))
      ≤ IRC_SAFE_PAYLOAD then
    paletteStep E (widthStep E (bisectStep E (pruneStep fg bg c₀)))
  else fallbackConfig

/-- The status line shown to the user: `none` when the picture was encoded, the
"too detailed" notice when the final guard had to fire. -/
def compressMessage (E : Encoder) (fg bg : Int) (c₀ : Config) : Option String :=
  if E.bytesOf (paletteStep E (widthStep E (bisectStep E (pruneStep fg bg c₀))))
      ≤ IRC_SAFE_PAYLOAD then none else some TOO_DETAILED_MESSAGE

/-- The pipeline always lands inside the safe payload budget of 400 bytes. -/
theorem compress_fits_payload (E : Encoder) (fg bg : Int) (c₀ : Config) :
    E.bytesOf (compress E fg bg c₀) ≤ IRC_SAFE_PAYLOAD := by
  unfold compress
  split
  · assumption
  · exact Nat.le_trans (E.cellBound fallbackConfig) fallback_fits

/-- **`fits_512`.**  After glyph pruning → Viterbi bisection → width shrink (down to
`MIN_IRC_WIDTH = 10`) → palette downgrade → final guard, the emitted IRC line, prefix
included, never exceeds `IRC_HARD_LIMIT = 512` bytes. -/
theorem fits_512 (E : Encoder) (fg bg : Int) (c₀ : Config) :
    IRC_PREFIX_RESERVE + E.bytesOf (compress E fg bg c₀) ≤ IRC_HARD_LIMIT := by
  have h := compress_fits_payload E fg bg c₀
  unfold IRC_PREFIX_RESERVE IRC_HARD_LIMIT IRC_SAFE_PAYLOAD at *
  omega

/-- The pipeline never produces a picture narrower than `MIN_IRC_WIDTH = 10`. -/
theorem compress_width_ge_min (E : Encoder) (fg bg : Int) (c₀ : Config)
    (h : MIN_IRC_WIDTH ≤ c₀.width) : MIN_IRC_WIDTH ≤ (compress E fg bg c₀).width := by
  unfold compress
  have hw : MIN_IRC_WIDTH ≤ (widthStep E (bisectStep E (pruneStep fg bg c₀))).width := by
    refine widthStep_ge_min E _ ?_
    unfold bisectStep pruneStep
    split <;> exact h
  split
  · unfold paletteStep
    split
    · exact hw
    · split <;> exact hw
  · exact Nat.le_refl _


/-! ## 7. The concrete Smart alphabet -/

/-- The Smart-detail candidate alphabet: 18 glyphs, all of whose half-cell coverages are
entries of `GLYPH_COVERAGES`.  The space costs `GLYPH_BYTES_SPACE = 1` byte, every block or
half block costs `GLYPH_BYTES_HALF = 3`. -/
def standardAlphabet : List Glyph :=
  [ { ct := 0,     cb := 0,     bytes := GLYPH_BYTES_SPACE }   -- ' '
  , { ct := 30000, cb := 30000, bytes := GLYPH_BYTES_HALF }    -- '█'
  , { ct := 30000, cb := 0,     bytes := GLYPH_BYTES_HALF }    -- '▀'
  , { ct := 0,     cb := 30000, bytes := GLYPH_BYTES_HALF }    -- '▄'
  , { ct := 3630,  cb := 3630,  bytes := GLYPH_BYTES_HALF }    -- '░'  0.121
  , { ct := 7620,  cb := 7620,  bytes := GLYPH_BYTES_HALF }    -- 0.254
  , { ct := 8190,  cb := 8190,  bytes := GLYPH_BYTES_HALF }    -- '▒'  0.273
  , { ct := 14835, cb := 14835, bytes := GLYPH_BYTES_HALF }    -- 0.4945
  , { ct := 16515, cb := 16515, bytes := GLYPH_BYTES_HALF }    -- 0.5055
  , { ct := 21810, cb := 21810, bytes := GLYPH_BYTES_HALF }    -- 0.727
  , { ct := 22380, cb := 22380, bytes := GLYPH_BYTES_HALF }    -- '▓'  0.746
  , { ct := 26370, cb := 26370, bytes := GLYPH_BYTES_HALF }    -- 0.879
  , { ct := 30000, cb := 8190,  bytes := GLYPH_BYTES_HALF }
  , { ct := 8190,  cb := 30000, bytes := GLYPH_BYTES_HALF }
  , { ct := 30000, cb := 16515, bytes := GLYPH_BYTES_HALF }
  , { ct := 16515, cb := 30000, bytes := GLYPH_BYTES_HALF }
  , { ct := 0,     cb := 8190,  bytes := GLYPH_BYTES_HALF }
  , { ct := 8190,  cb := 0,     bytes := GLYPH_BYTES_HALF } ]

theorem standardAlphabet_length : standardAlphabet.length = MAX_ALPHABET := rfl

/-- Every glyph of the candidate alphabet is built from `GLYPH_COVERAGES` and costs either
`GLYPH_BYTES_SPACE` or `GLYPH_BYTES_HALF` bytes. -/
theorem standardAlphabet_wf :
    ∀ g ∈ standardAlphabet, g.ct ∈ GLYPH_COVERAGES ∧ g.cb ∈ GLYPH_COVERAGES ∧
      (g.bytes = GLYPH_BYTES_SPACE ∨ g.bytes = GLYPH_BYTES_HALF) := by decide

/-- Byte-gap dominance only gets easier as the Viterbi weight grows. -/
theorem dominance_monotone_in_w (w₁ w₂ : Nat) (hw : w₁ ≤ w₂) (fg bg : Int) (g h : Glyph)
    (hdom : glyphDominatedByByteGap w₁ fg bg g h = true) :
    glyphDominatedByByteGap w₂ fg bg g h = true := by
  unfold glyphDominatedByByteGap at *
  simp only [Bool.and_eq_true, decide_eq_true_eq] at *
  exact ⟨hdom.1, Nat.le_trans hdom.2 (Nat.mul_le_mul_right _ hw)⟩

/-- Hence the Pareto frontier shrinks as the Viterbi weight grows: raising `viterbiW` can
only remove glyphs from the alphabet, never add them. -/
theorem pareto_frontier_antitone_in_w (w₁ w₂ : Nat) (hw : w₁ ≤ w₂) (fg bg : Int)
    (A : List Glyph) (g : Glyph) (hg : g ∈ paretoPrune w₂ fg bg A) :
    g ∈ paretoPrune w₁ fg bg A := by
  obtain ⟨hgA, hkeep⟩ := List.mem_filter.mp hg
  refine List.mem_filter.mpr ⟨hgA, ?_⟩
  simp only [Bool.not_eq_true', Bool.not_eq_true, List.any_eq_false] at hkeep ⊢
  intro g' hg'
  have h2 := hkeep g' hg'
  cases hb : glyphDominatedByByteGap w₁ fg bg g' g with
  | false => rfl
  | true =>
    rw [dominance_monotone_in_w w₁ w₂ hw fg bg g' g hb] at h2
    exact Bool.noConfusion h2

/-- **`pareto_optimal` at the sweet spot.**  For any Viterbi weight in the sweet-spot band
`viterbiW ∈ [2,4]` (half steps `4 ≤ k ≤ 8`), the pruned alphabet still realises the minimal
cell cost of the full alphabet: for every glyph there is a survivor that is at least as good
on every cell.  So no alphabet — in particular none using more bytes per cell — beats the
pruned one. -/
theorem viterbiWeight_mono (k₁ k₂ : Nat) (h : k₁ ≤ k₂) : viterbiWeight k₁ ≤ viterbiWeight k₂ :=
  Nat.mul_le_mul_left _ h

theorem pareto_optimal_sweet_spot (k : Nat) (hk : VITERBI_SWEET_SPOT ≤ k)
    (hk' : k ≤ 2 * VITERBI_SWEET_SPOT) (fg bg : Int) (A : List Glyph) (g : Glyph) (hg : g ∈ A) :
    (∃ g' ∈ paretoPrune (viterbiWeight k) fg bg A, ∀ tTop tBot : Int,
        cellCost (viterbiWeight k) g' tTop tBot fg bg
          ≤ cellCost (viterbiWeight k) g tTop tBot fg bg) ∧
      (∀ x ∈ paretoPrune (viterbiWeight k) fg bg A,
        x ∈ paretoPrune (viterbiWeight VITERBI_SWEET_SPOT) fg bg A) ∧
      (∀ x ∈ paretoPrune (viterbiWeight (2 * VITERBI_SWEET_SPOT)) fg bg A,
        x ∈ paretoPrune (viterbiWeight k) fg bg A) := by
  refine ⟨pareto_optimal (viterbiWeight k) fg bg A g hg, ?_, ?_⟩
  · exact fun x hx => pareto_frontier_antitone_in_w _ _ (viterbiWeight_mono _ _ hk) fg bg A x hx
  · exact fun x hx => pareto_frontier_antitone_in_w _ _ (viterbiWeight_mono _ _ hk') fg bg A x hx

/-- In a mid-contrast cell (`contrast = 12` luma levels) the sweet spot `viterbiW = 2` prunes
the 18 candidate glyphs to a Pareto frontier of 15, and `viterbiW = 4` to one of 13 — both
inside the `12..18` window Smart detail asks for. -/
theorem standardAlphabet_frontier_sizes :
    (paretoPrune (viterbiWeight VITERBI_SWEET_SPOT) 12 0 standardAlphabet).length = 15 ∧
    (paretoPrune (viterbiWeight (2 * VITERBI_SWEET_SPOT)) 12 0 standardAlphabet).length = 13 := by
  refine ⟨by decide, by decide⟩

theorem standardAlphabet_frontier_in_window :
    MIN_ALPHABET ≤ (paretoPrune (viterbiWeight VITERBI_SWEET_SPOT) 12 0 standardAlphabet).length ∧
      (paretoPrune (viterbiWeight VITERBI_SWEET_SPOT) 12 0 standardAlphabet).length
        ≤ MAX_ALPHABET := by
  refine ⟨by decide, by decide⟩

/-- In a flat cell (`contrast ≤ 2`) everything collapses onto the 1-byte space: pruning
alone already gives the cheapest possible rendering of such a cell. -/
theorem standardAlphabet_flat_cell_is_space :
    paretoPrune (viterbiWeight VITERBI_SWEET_SPOT) 2 0 standardAlphabet =
      [{ ct := 0, cb := 0, bytes := GLYPH_BYTES_SPACE }] := by decide

/-- **Main theorem: `∃ alphabet K, ∀ cell, cellCost minimal ∧ Σ bytes ≤ 512`.**

For every image configuration there is an alphabet `K` — the byte-gap Pareto frontier of the
candidate alphabet at the chosen Viterbi weight — such that

* `K` is no bigger than the candidate alphabet;
* every cell can be rendered from `K` at least as cheaply as from the full alphabet, whatever
  its two target lumas are (so the per-cell cost is minimal over the full alphabet);
* the line the deterministic pipeline emits — glyph pruning, Viterbi bisection, width shrink
  down to 10 columns, palette downgrade, final guard — is at most
  `IRC_HARD_LIMIT = 512` bytes including the PRIVMSG prefix reserve. -/
theorem exists_optimal_alphabet_fitting_512 (E : Encoder) (fg bg : Int) (c₀ : Config) :
    ∃ K : List Glyph,
      K.length ≤ c₀.alphabet.length ∧
      (∀ g ∈ c₀.alphabet, ∃ g' ∈ K, ∀ tTop tBot : Int,
        cellCost (viterbiWeight c₀.wHalf) g' tTop tBot fg bg
          ≤ cellCost (viterbiWeight c₀.wHalf) g tTop tBot fg bg) ∧
      IRC_PREFIX_RESERVE + E.bytesOf (compress E fg bg c₀) ≤ IRC_HARD_LIMIT := by
  refine ⟨paretoPrune (viterbiWeight c₀.wHalf) fg bg c₀.alphabet,
    paretoPrune_length_le _ fg bg _, ?_, fits_512 E fg bg c₀⟩
  intro g hg
  exact pareto_optimal (viterbiWeight c₀.wHalf) fg bg c₀.alphabet g hg


end GlyphSmart
