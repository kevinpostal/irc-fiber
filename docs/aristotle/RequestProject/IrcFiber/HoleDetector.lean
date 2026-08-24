import Std

namespace IrcFiber.HoleDetector

/-!
HoleDetector, mirroring `frontend/src/lib/wsHoleDetector.ts`:

  onEid:   ascending eids are appended into a 20-entry ring window;
           out-of-order eids reset the window to [eid]; eid ≤ 0 ignored.
  checkForHole: returns the FIRST adjacent pair (prev, curr) whose gap
           (curr - prev - 1) exceeds the threshold, unless in cooldown.

Proved here: gap arithmetic, findHole soundness, window size bound.
Sorries (Aristotle): first-pair minimality, window ascending invariant,
cooldown no-fetch-storm.
-/

-- Number of missing events between a and b (0 when not ascending).
def gap (a b : Nat) : Nat := if a < b then b - a - 1 else 0

theorem gap_pos_implies_lt : ∀ a b, 0 < gap a b → a < b := by
  intro a b h
  unfold gap at h
  by_cases hlt : a < b
  · exact hlt
  · simp [hlt] at h

theorem gap_underflow_is_zero : ∀ a b, ¬ a < b → gap a b = 0 := by
  intro a b h
  simp [gap, h]

-- Adjacent pairs of a window (the only places a hole can be seen).
def adjacentPairs : List Nat → List (Nat × Nat)
  | [] => []
  | [_] => []
  | a :: b :: rest => (a, b) :: adjacentPairs (b :: rest)

-- findHole returns the first adjacent pair whose gap exceeds the
-- threshold (mirrors checkForHole's loop; cooldown is handled by the
-- caller).
def findHole : List Nat → Nat → Option (Nat × Nat)
  | [], _ => none
  | [_], _ => none
  | a :: b :: rest, t => if t < gap a b then some (a, b) else findHole (b :: rest) t

-- Soundness: any hole findHole reports is a genuine ascending gap
-- strictly larger than the threshold, and it is an adjacent pair of the
-- window.
theorem findHole_sound : ∀ w t a b,
    findHole w t = some (a, b) → a < b ∧ t < gap a b ∧ (a, b) ∈ adjacentPairs w := by
  intro w
  induction w with
  | nil =>
      intro t a b h
      simp [findHole] at h
  | cons c cs ih =>
      intro t a b h
      cases cs with
      | nil => simp [findHole] at h
      | cons d ds =>
          by_cases ht : t < gap c d
          · have h' : findHole (c :: d :: ds) t = some (c, d) := by
              simp [findHole, ht]
            have h'' : some (c, d) = some (a, b) := by
              simpa [h'] using h
            have hpair : (c, d) = (a, b) := by
              simpa using h''
            have h1 : c = a := congrArg Prod.fst hpair
            have h2 : d = b := congrArg Prod.snd hpair
            subst a; subst b
            have hpos : 0 < gap c d := by omega
            exact ⟨gap_pos_implies_lt c d hpos, ht, by simp [adjacentPairs]⟩
          · simp [findHole, ht] at h
            have hrec := ih t a b h
            exact ⟨hrec.1, hrec.2.1, by simp [adjacentPairs]; exact Or.inr hrec.2.2⟩

-- Completeness: no hole is reported iff every adjacent gap is within
-- the threshold (the "does not detect a hole with contiguous eids" /
-- "small gap ≤ threshold" behaviours pinned by wsHoleDetector.test.ts).
theorem findHole_none_iff : ∀ w t,
    findHole w t = none ↔ ∀ a b, (a, b) ∈ adjacentPairs w → gap a b ≤ t := by
  intro w
  induction w with
  | nil => intro t; simp [findHole, adjacentPairs]
  | cons c cs ih =>
      intro t
      cases cs with
      | nil => simp [findHole, adjacentPairs]
      | cons d ds =>
          by_cases ht : t < gap c d
          · simp only [findHole, if_pos ht, adjacentPairs]
            constructor
            · intro h; exact absurd h (by simp)
            · intro h
              have := h c d (by simp)
              omega
          · simp only [findHole, if_neg ht, adjacentPairs]
            rw [ih t]
            constructor
            · intro h a b hmem
              rcases List.mem_cons.1 hmem with heq | hmem'
              · obtain ⟨rfl, rfl⟩ : a = c ∧ b = d := by simpa using heq
                omega
              · exact h a b hmem'
            · intro h a b hmem
              exact h a b (by simp [hmem])

-- Ascending window: every adjacent pair strictly increases.  This is
-- the invariant maintained by `onEid` (see `window_ascending_preserved`).
def Ascending (w : List Nat) : Prop := ∀ a b, (a, b) ∈ adjacentPairs w → a < b

-- In an ascending list, every adjacent pair starts at or after the head.
theorem ascending_pair_ge_head : ∀ h l, Ascending (h :: l) →
    ∀ x y, (x, y) ∈ adjacentPairs (h :: l) → h ≤ x := by
  intro h l
  induction l generalizing h with
  | nil => intro _ x y hmem; simp [adjacentPairs] at hmem
  | cons e es ih =>
      intro hasc x y hmem
      have htail : Ascending (e :: es) := by
        intro a b hab
        exact hasc a b (by simp [adjacentPairs, hab])
      rw [adjacentPairs] at hmem
      rcases List.mem_cons.1 hmem with heq | hmem'
      · obtain ⟨rfl, rfl⟩ : x = h ∧ y = e := by simpa using heq
        omega
      · have hle := ih e htail x y hmem'
        have hlt : h < e := hasc h e (by simp [adjacentPairs])
        omega

-- The returned pair is the FIRST exceeding pair, in the syntactic sense:
-- the pair list splits as `pre ++ (a, b) :: post` with every pair in
-- `pre` within the threshold.
theorem findHole_first_prefix : ∀ w t a b,
    findHole w t = some (a, b) →
    ∃ pre post, adjacentPairs w = pre ++ (a, b) :: post ∧
      ∀ p ∈ pre, gap p.1 p.2 ≤ t := by
  intro w
  induction w with
  | nil => intro t a b h; simp [findHole] at h
  | cons c cs ih =>
      intro t a b h
      cases cs with
      | nil => simp [findHole] at h
      | cons d ds =>
          by_cases ht : t < gap c d
          · rw [findHole, if_pos ht] at h
            have hpair : (c, d) = (a, b) := by simpa using h
            refine ⟨[], adjacentPairs (d :: ds), ?_, by simp⟩
            simp [adjacentPairs, hpair]
          · rw [findHole, if_neg ht] at h
            obtain ⟨pre, post, hsplit, hpre⟩ := ih t a b h
            refine ⟨(c, d) :: pre, post, ?_, ?_⟩
            · simp [adjacentPairs, hsplit]
            · intro p hp
              rcases List.mem_cons.1 hp with rfl | hp'
              · simpa using (by omega : gap c d ≤ t)
              · exact hpre p hp'

/-
SORRY (original statement) — FALSE as stated.  The intended reading of
"first" is positional, but the statement orders pairs by `y < b`, which
only matches the positional order when the window is ascending.  See
`findHole_first_counterexample` below for a concrete refutation, and
`findHole_first_prefix` / `findHole_first_ascending` for correct versions.

theorem findHole_first : ∀ w t a b,
    findHole w t = some (a, b) →
    ∀ x y, (x, y) ∈ adjacentPairs w → y < b → gap x y ≤ t := by
  sorry
-/

-- Counterexample to the statement above: on the (non-ascending) window
-- [0, 100, 0, 50] with threshold 10, findHole reports (0, 100) while the
-- later pair (0, 50) also exceeds the threshold and has 50 < 100.
theorem findHole_first_counterexample :
    ¬ (∀ w t a b, findHole w t = some (a, b) →
        ∀ x y, (x, y) ∈ adjacentPairs w → y < b → gap x y ≤ t) := by
  intro h
  have hfind : findHole [0, 100, 0, 50] 10 = some (0, 100) := by decide
  have hmem : ((0 : Nat), (50 : Nat)) ∈ adjacentPairs [0, 100, 0, 50] := by decide
  have := h [0, 100, 0, 50] 10 0 100 hfind 0 50 hmem (by omega)
  simp [gap] at this

-- Corrected version: on an ascending window (the invariant `onEid`
-- maintains) the reported pair really is the first exceeding one, in the
-- `y < b` ordering of the original statement.
theorem findHole_first_ascending : ∀ w t a b,
    Ascending w → findHole w t = some (a, b) →
    ∀ x y, (x, y) ∈ adjacentPairs w → y < b → gap x y ≤ t := by
  intro w
  induction w with
  | nil => intro t a b _ h; simp [findHole] at h
  | cons c cs ih =>
      intro t a b hasc h x y hmem hy
      cases cs with
      | nil => simp [findHole] at h
      | cons d ds =>
          have htail : Ascending (d :: ds) := by
            intro p q hpq
            exact hasc p q (by simp [adjacentPairs, hpq])
          rw [adjacentPairs] at hmem
          have hmem' := List.mem_cons.1 hmem
          by_cases ht : t < gap c d
          · rw [findHole, if_pos ht] at h
            obtain ⟨rfl, rfl⟩ : c = a ∧ d = b := by simpa using h
            rcases hmem' with heq | hin
            · obtain ⟨rfl, rfl⟩ : x = c ∧ y = d := by simpa using heq
              omega
            · have hge := ascending_pair_ge_head d ds htail x y hin
              have hlt : x < y := htail x y hin
              omega
          · rw [findHole, if_neg ht] at h
            rcases hmem' with heq | hin
            · obtain ⟨rfl, rfl⟩ : x = c ∧ y = d := by simpa using heq
              omega
            · exact ih t a b htail h x y hin hy

-- Window ring-buffer bound: onEid never grows the window past 20.
def trim20 (l : List Nat) : List Nat :=
  if l.length ≤ 20 then l else l.drop (l.length - 20)

theorem trim20_size : ∀ l, (trim20 l).length ≤ 20 := by
  intro l
  unfold trim20
  by_cases h : l.length ≤ 20
  · simp [h]
  · simp [h]
    omega

-- onEid: ascending → append+trim; out-of-order → reset; eid = 0 ignored.
def onEid (w : List Nat) (e : Nat) : List Nat :=
  if e = 0 then w
  else match w.getLast? with
    | none => trim20 [e]
    | some last => if last < e then trim20 (w ++ [e]) else [e]

theorem onEid_ignores_zero : ∀ w, onEid w 0 = w := by
  intro w
  simp [onEid]

theorem onEid_size : ∀ w e, w.length ≤ 20 → (onEid w e).length ≤ 20 := by
  intro w e h
  unfold onEid
  by_cases he : e = 0
  · simp [he, h]
  · cases hlast : w.getLast? with
    | none =>
        simp [he, hlast]
        exact trim20_size [e]
    | some last =>
        by_cases hlt : last < e
        · simp [he, hlast, hlt]
          exact trim20_size (w ++ [e])
        · simp [he, hlast, hlt]

-- Adjacent pairs of a tail are adjacent pairs of the whole list.
theorem adjacentPairs_tail_subset : ∀ (x : Nat) (l : List Nat) p,
    p ∈ adjacentPairs l → p ∈ adjacentPairs (x :: l) := by
  intro x l p hp
  cases l with
  | nil => simp [adjacentPairs] at hp
  | cons y ys => simp [adjacentPairs]; exact Or.inr hp

-- Dropping a prefix keeps every adjacent pair.
theorem adjacentPairs_drop_subset : ∀ (n : Nat) (l : List Nat) p,
    p ∈ adjacentPairs (l.drop n) → p ∈ adjacentPairs l := by
  intro n
  induction n with
  | zero => intro l p hp; simpa using hp
  | succ n ih =>
      intro l p hp
      cases l with
      | nil => simp [adjacentPairs] at hp
      | cons x xs =>
          have : p ∈ adjacentPairs xs := ih xs p (by simpa using hp)
          exact adjacentPairs_tail_subset x xs p this

-- Dropping a prefix of an ascending list keeps it ascending.
theorem ascending_drop : ∀ n l, Ascending l → Ascending (l.drop n) := by
  intro n l h a b hab
  exact h a b (adjacentPairs_drop_subset n l (a, b) hab)

-- Appending a strictly larger element to the end keeps a list ascending.
theorem ascending_append_last : ∀ l last e, l.getLast? = some last → last < e →
    Ascending l → Ascending (l ++ [e]) := by
  intro l
  induction l with
  | nil => intro last e h; simp at h
  | cons x xs ih =>
      intro last e hlast hlt hasc
      cases xs with
      | nil =>
          have hx : x = last := by simpa using hlast
          subst hx
          intro a b hab
          simp [adjacentPairs] at hab
          obtain ⟨rfl, rfl⟩ := hab
          exact hlt
      | cons y ys =>
          have hlast' : (y :: ys).getLast? = some last := by
            simpa using hlast
          have htail : Ascending (y :: ys) := by
            intro a b hab
            exact hasc a b (adjacentPairs_tail_subset x (y :: ys) (a, b) hab)
          have hrec := ih last e hlast' hlt htail
          intro a b hab
          have : adjacentPairs ((x :: y :: ys) ++ [e])
              = (x, y) :: adjacentPairs ((y :: ys) ++ [e]) := by
            simp [adjacentPairs]
          rw [this] at hab
          rcases List.mem_cons.1 hab with heq | hin
          · obtain ⟨rfl, rfl⟩ : a = x ∧ b = y := by simpa using heq
            exact hasc a b (by simp [adjacentPairs])
          · exact hrec a b hin

-- Trimming the ring buffer keeps it ascending.
theorem ascending_trim20 : ∀ l, Ascending l → Ascending (trim20 l) := by
  intro l h
  unfold trim20
  by_cases hlen : l.length ≤ 20
  · simpa [hlen] using h
  · simp only [hlen, if_false]
    exact ascending_drop _ _ h

-- An ascending window stays ascending (no hole is ever manufactured by
-- the window bookkeeping itself).
theorem window_ascending_preserved : ∀ w e,
    w ≠ [] → (∀ a b, (a, b) ∈ adjacentPairs w → a < b) →
    (∀ a b, (a, b) ∈ adjacentPairs (onEid w e) → a < b) := by
  intro w e hne hasc
  have hasc' : Ascending w := hasc
  unfold onEid
  by_cases he : e = 0
  · simpa [he] using hasc'
  · cases hlast : w.getLast? with
    | none =>
        exact absurd (List.getLast?_eq_none_iff.1 hlast) hne
    | some last =>
        by_cases hlt : last < e
        · have happ : Ascending (w ++ [e]) := ascending_append_last w last e hlast hlt hasc'
          have htrim : Ascending (trim20 (w ++ [e])) := ascending_trim20 _ happ
          simp only [he, if_false, hlt, if_true]
          exact htrim
        · simp only [he, if_false, hlt, if_false]
          intro a b hab
          simp [adjacentPairs] at hab

-- Cooldown — consecutive OOB fetches are at least cooldownMs apart, so a
-- pathological gap cannot cause a fetch storm: once the cooldown has
-- expired it stays expired, and (contrapositively) before cooldownMs has
-- elapsed no second fetch is allowed.
def cooldownActive (lastFetchAt t cooldownMs : Nat) : Bool := t - lastFetchAt < cooldownMs
theorem cooldown_prevents_storm : ∀ lastFetchAt t1 t2 cooldownMs,
    cooldownMs > 0 → lastFetchAt ≤ t1 → t1 ≤ t2 →
    cooldownActive lastFetchAt t1 cooldownMs = false →
    cooldownActive lastFetchAt t2 cooldownMs = false := by
  intro lastFetchAt t1 t2 cooldownMs _ _ h12 h1
  simp only [cooldownActive, decide_eq_false_iff_not, Nat.not_lt] at h1 ⊢
  omega

-- The safety consequence: a fetch is only permitted when the cooldown is
-- inactive, so two permitted fetches at times t1 ≤ t2 with lastFetchAt
-- updated to t1 are at least cooldownMs apart.
theorem cooldown_gap_between_fetches : ∀ t1 t2 cooldownMs,
    t1 ≤ t2 → cooldownActive t1 t2 cooldownMs = false → t1 + cooldownMs ≤ t2 := by
  intro t1 t2 cooldownMs h12 h
  simp only [cooldownActive, decide_eq_false_iff_not, Nat.not_lt] at h
  omega

end IrcFiber.HoleDetector
