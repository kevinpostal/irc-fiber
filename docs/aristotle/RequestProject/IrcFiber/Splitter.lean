import Std

namespace IrcFiber.Splitter

/-!
Message splitter + batcher, mirroring
`frontend/src/lib/messageSplitter.ts` (hard-break + greedy pack) and
`frontend/src/lib/messageBatcher.ts` (coalesced flush).

Proved here: the greedy pack never emits an over-long message (the
512-byte / safe-payload safety invariant).  Sorries (Aristotle):
hard-break chunk length bound + tiling, greedy optimality (minimal
message count), pack maximality (adjacent messages cannot be joined),
batcher order-preservation.
-/

-- ── Hard break ────────────────────────────────────────────────────

-- Split a list into chunks of length ≤ m (all but the last exactly m
-- when the input is longer than m and m > 0).
def chunks {α} (l : List α) (m : Nat) : List (List α) :=
  if h : m = 0 then [l]
  else if h2 : l.length ≤ m then [l]
  else l.take m :: chunks (l.drop m) m
termination_by l.length
decreasing_by
  simp_wf
  omega

-- `chunks` always emits at least one chunk.
theorem chunks_ne_nil : ∀ {α} (l : List α) (m : Nat), chunks l m ≠ [] := by
  intro α l m
  rw [chunks]
  by_cases hm : m = 0
  · simp [hm]
  · rw [dif_neg hm]
    by_cases h2 : l.length ≤ m
    · simp [h2]
    · simp [h2]

-- Chunks tile the input — concatenating them reproduces the original
-- (no text is lost or duplicated).
theorem chunks_tile_aux : ∀ {α} (m : Nat), m > 0 → ∀ (n : Nat) (l : List α),
    l.length ≤ n → List.flatten (chunks l m) = l := by
  intro α m hm n
  have hm0 : ¬ (m = 0) := by omega
  induction n with
  | zero =>
      intro l hl
      have hnil : l = [] := List.eq_nil_of_length_eq_zero (by omega)
      subst hnil
      rw [chunks, dif_neg hm0, dif_pos (by simp)]
      simp
  | succ n ih =>
      intro l hl
      rw [chunks, dif_neg hm0]
      by_cases h2 : l.length ≤ m
      · rw [dif_pos h2]; simp
      · rw [dif_neg h2]
        have hdrop : (l.drop m).length ≤ n := by
          rw [List.length_drop]; omega
        rw [List.flatten_cons, ih (l.drop m) hdrop, List.take_append_drop]

theorem chunks_tile : ∀ {α} (l : List α) (m : Nat), m > 0 → List.flatten (chunks l m) = l := by
  intro α l m hm
  exact chunks_tile_aux m hm l.length l (Nat.le_refl _)

-- Chunks are never longer than m.
theorem chunks_length_le_aux : ∀ {α} (m : Nat), m > 0 → ∀ (n : Nat) (l : List α),
    l.length ≤ n → ∀ c ∈ chunks l m, c.length ≤ m := by
  intro α m hm n
  have hm0 : ¬ (m = 0) := by omega
  induction n with
  | zero =>
      intro l hl c hc
      have hnil : l = [] := List.eq_nil_of_length_eq_zero (by omega)
      subst hnil
      rw [chunks, dif_neg hm0, dif_pos (by simp)] at hc
      simp at hc
      subst hc
      simp
  | succ n ih =>
      intro l hl c hc
      rw [chunks, dif_neg hm0] at hc
      by_cases h2 : l.length ≤ m
      · rw [dif_pos h2] at hc
        simp at hc
        subst hc
        exact h2
      · rw [dif_neg h2] at hc
        have hdrop : (l.drop m).length ≤ n := by
          rw [List.length_drop]; omega
        rcases List.mem_cons.1 hc with rfl | hc'
        · rw [List.length_take]; omega
        · exact ih (l.drop m) hdrop c hc'

theorem chunks_length_le : ∀ {α} (l : List α) (m : Nat), m > 0 → ∀ c ∈ chunks l m, c.length ≤ m := by
  intro α l m hm
  exact chunks_length_le_aux m hm l.length l (Nat.le_refl _)

-- All but the last chunk have length exactly m (the tightness property
-- the wire-budget relies on).  This holds unconditionally: when at most
-- one chunk is produced, `dropLast` is empty.
theorem chunks_interior_exact_aux : ∀ {α} (m : Nat), m > 0 → ∀ (n : Nat) (l : List α),
    l.length ≤ n → ∀ c ∈ (chunks l m).dropLast, c.length = m := by
  intro α m hm n
  have hm0 : ¬ (m = 0) := by omega
  induction n with
  | zero =>
      intro l hl c hc
      have hnil : l = [] := List.eq_nil_of_length_eq_zero (by omega)
      subst hnil
      rw [chunks, dif_neg hm0, dif_pos (by simp)] at hc
      simp at hc
  | succ n ih =>
      intro l hl c hc
      rw [chunks, dif_neg hm0] at hc
      by_cases h2 : l.length ≤ m
      · rw [dif_pos h2] at hc
        simp at hc
      · rw [dif_neg h2] at hc
        have hdrop : (l.drop m).length ≤ n := by
          rw [List.length_drop]; omega
        have hne : chunks (l.drop m) m ≠ [] := chunks_ne_nil (l.drop m) m
        cases hrest : chunks (l.drop m) m with
        | nil => exact absurd hrest hne
        | cons d ds =>
            rw [hrest, List.dropLast_cons₂] at hc
            rcases List.mem_cons.1 hc with rfl | hc'
            · rw [List.length_take]; omega
            · exact ih (l.drop m) hdrop c (by rw [hrest]; exact hc')

/--
All but the last chunk have length exactly m.  (The hypothesis
`1 < (chunks l m).length` from the original statement is kept, but the
property in fact holds unconditionally — see `chunks_interior_exact_aux`.)
-/
theorem chunks_interior_exact : ∀ {α} (l : List α) (m : Nat), m > 0 → 1 < (chunks l m).length → ∀ c ∈ (chunks l m).dropLast, c.length = m := by
  intro α l m hm _
  exact chunks_interior_exact_aux m hm l.length l (Nat.le_refl _)

-- ── Greedy pack ───────────────────────────────────────────────────

-- packWith buf lines m: greedy single-space join.  buf is the
-- accumulator (none = empty).  A blank line flushes the accumulator.
-- A line joins the accumulator iff the joined length stays ≤ m.
def packWith (buf : Option String) (lines : List String) (m : Nat) : List String :=
  match lines with
  | [] => match buf with | some b => [b] | none => []
  | line :: rest =>
      if line = "" then
        match buf with
        | some b => b :: packWith none rest m
        | none => packWith none rest m
      else match buf with
        | some b =>
            if b.length + 1 + line.length ≤ m then packWith (some (b ++ " " ++ line)) rest m
            else b :: packWith (some line) rest m
        | none => packWith (some line) rest m

def pack (lines : List String) (m : Nat) : List String := packWith none lines m

-- Safety: when every input line already fits in m (splitIntoMessages
-- hard-breaks before packing), every packed message is ≤ m — the
-- 512-byte / safe-payload budget is never exceeded.
theorem pack_fits : ∀ lines m, m > 0 → (∀ line ∈ lines, line.length ≤ m) →
    ∀ msg ∈ pack lines m, msg.length ≤ m := by
  intro lines m hm hlines msg hmem
  exact packWith_fits none lines m hm (by trivial) hlines msg (by simpa [pack] using hmem)
where
  packWith_fits : ∀ buf lines m, m > 0 →
      (match buf with | some b => b.length ≤ m | none => True) →
      (∀ line ∈ lines, line.length ≤ m) →
      ∀ msg ∈ packWith buf lines m, msg.length ≤ m := by
    intro buf lines m hm hbuf hlines
    revert hlines m hm hbuf buf
    induction lines with
    | nil =>
        intro buf m hm hbuf hlines msg hmem
        cases buf with
        | none => simp [packWith] at hmem
        | some b => simp [packWith] at hmem; subst msg; exact hbuf
    | cons line rest ih =>
        intro buf m hm hbuf hlines msg hmem
        have hline_fits : line.length ≤ m := hlines line (by simp)
        have htail : ∀ l ∈ rest, l.length ≤ m := by
          intro l hl
          exact hlines l (by simp [hl])
        by_cases hline : line = ""
        · cases buf with
          | none =>
              simp [packWith, hline] at hmem
              exact ih none m hm (by trivial) htail msg hmem
          | some b =>
              simp [packWith, hline] at hmem
              rcases hmem with hmsg | hrest
              · subst msg; exact hbuf
              · exact ih none m hm (by trivial) htail msg hrest
        · cases buf with
          | none =>
              simp [packWith, hline] at hmem
              exact ih (some line) m hm (by simp [hline_fits]) htail msg hmem
          | some b =>
              by_cases hfit : b.length + 1 + line.length ≤ m
              · simp [packWith, hline, hfit] at hmem
                exact ih (some (b ++ " " ++ line)) m hm
                  (by
                    change (b ++ " " ++ line).length ≤ m
                    rw [String.length_append]
                    rw [String.length_append]
                    have hs : " ".length = 1 := by native_decide
                    rw [hs]
                    omega) htail msg hmem
              · simp [packWith, hline, hfit] at hmem
                rcases hmem with hmsg | hrest
                · subst msg; exact hbuf
                · exact ih (some line) m hm (by simp [hline_fits]) htail msg hrest

-- Length of a single-space join.
theorem sjoin_length : ∀ (b l : String), (b ++ " " ++ l).length = b.length + 1 + l.length := by
  intro b l
  rw [String.length_append, String.length_append]
  have hs : " ".length = 1 := rfl
  rw [hs]

-- The first message emitted from a non-empty accumulator is at least as
-- long as the accumulator (the accumulator only ever grows).
theorem packWith_head_ge : ∀ (lines : List String) (m : Nat) (b hd : String) (tl : List String),
    packWith (some b) lines m = hd :: tl → b.length ≤ hd.length := by
  intro lines
  induction lines with
  | nil =>
      intro m b hd tl h
      simp [packWith] at h
      exact Nat.le_of_eq (congrArg String.length h.1)
  | cons line rest ih =>
      intro m b hd tl h
      by_cases hline : line = ""
      · simp [packWith, hline] at h
        exact Nat.le_of_eq (congrArg String.length h.1)
      · by_cases hfit : b.length + 1 + line.length ≤ m
        · simp only [packWith, if_neg hline, hfit, if_true] at h
          have := ih m (b ++ " " ++ line) hd tl h
          rw [sjoin_length] at this
          omega
        · simp only [packWith, if_neg hline, hfit, if_false] at h
          have hbhd : b = hd := by
            have := congrArg List.head? h
            simpa using this
          exact Nat.le_of_eq (congrArg String.length hbhd)

/-
SORRY (original statement) — FALSE as stated.  It quantifies over *any*
two packed messages A, B, but a blank input line flushes the accumulator,
so two short messages can coexist with their join in the same pack.  See
`pack_maximal_adjacent_counterexample`, and
`pack_maximal_adjacent_consecutive` for the correct (consecutive, blank-free)
version.

theorem pack_maximal_adjacent : ∀ lines m, m > 0 → (∀ line ∈ lines, line.length ≤ m) →
    ∀ A B, A ∈ pack lines m → B ∈ pack lines m → A ≠ "" → B ≠ "" →
    (∃ x, x ∈ pack lines m ∧ x = A ++ " " ++ B) → False := by
  sorry
-/

-- Counterexample: with m = 5 and the blank-separated input
-- ["ab", "", "cd", "", "ab cd"] the pack is ["ab", "cd", "ab cd"], which
-- contains "ab", "cd" and their join "ab cd".
theorem pack_maximal_adjacent_counterexample :
    ¬ (∀ lines m, m > 0 → (∀ line ∈ lines, line.length ≤ m) →
        ∀ A B, A ∈ pack lines m → B ∈ pack lines m → A ≠ "" → B ≠ "" →
        (∃ x, x ∈ pack lines m ∧ x = A ++ " " ++ B) → False) := by
  intro h
  have hlines : ∀ line ∈ ["ab", "", "cd", "", "ab cd"], line.length ≤ 5 := by
    decide
  have hpack : pack ["ab", "", "cd", "", "ab cd"] 5 = ["ab", "cd", "ab cd"] := by decide
  refine h ["ab", "", "cd", "", "ab cd"] 5 (by omega) hlines "ab" "cd"
    (by rw [hpack]; simp) (by rw [hpack]; simp) (by decide) (by decide) ?_
  exact ⟨"ab cd", by rw [hpack]; simp, by decide⟩

/--
Maximality (corrected): for blank-free input, *consecutive* packed
messages A, B satisfy `m < A.length + 1 + B.length`, i.e. the greedy pack
is not extendable under the budget.  A blank input line flushes the
accumulator, which is why blank-free input is required (see
`pack_maximal_adjacent_counterexample`).
-/
theorem packWith_maximal_consecutive : ∀ (lines : List String) (m : Nat) (buf : Option String),
    (∀ line ∈ lines, line ≠ "") →
    ∀ pre A B post, packWith buf lines m = pre ++ A :: B :: post →
      m < A.length + 1 + B.length := by
  intro lines
  induction lines with
  | nil =>
      intro m buf _ pre A B post h
      have hlen := congrArg List.length h
      cases buf with
      | none => simp [packWith] at hlen; omega
      | some b => simp [packWith] at hlen; omega
  | cons line rest ih =>
      intro m buf hne pre A B post h
      have hline : line ≠ "" := hne line (by simp)
      have hrest : ∀ l ∈ rest, l ≠ "" := fun l hl => hne l (by simp [hl])
      cases buf with
      | none =>
          simp only [packWith, if_neg hline] at h
          exact ih m (some line) hrest pre A B post h
      | some b =>
          by_cases hfit : b.length + 1 + line.length ≤ m
          · simp only [packWith, if_neg hline, hfit, if_true] at h
            exact ih m (some (b ++ " " ++ line)) hrest pre A B post h
          · simp only [packWith, if_neg hline, hfit, if_false] at h
            cases pre with
            | nil =>
                simp at h
                have hA : b = A := h.1
                have hAl : b.length = A.length := congrArg String.length hA
                have htail : packWith (some line) rest m = B :: post := h.2
                have hB : line.length ≤ B.length :=
                  packWith_head_ge rest m line B post htail
                omega
            | cons p pre' =>
                simp at h
                exact ih m (some line) hrest pre' A B post h.2

theorem pack_maximal_adjacent_consecutive : ∀ (lines : List String) (m : Nat),
    (∀ line ∈ lines, line ≠ "") →
    ∀ pre A B post, pack lines m = pre ++ A :: B :: post →
      m < A.length + 1 + B.length := by
  intro lines m hne pre A B post h
  exact packWith_maximal_consecutive lines m none hne pre A B post h

-- ── Optimality ───────────────────────────────────────────────────

/-
SORRY (original statement) — FALSE as stated: `ValidPack lines m msgs`
does not relate `msgs` to `lines` at all, so the empty list is a "valid
pack" of any input.  See `pack_optimal_counterexample`; the corrected
statement (`pack_optimal_correct`) uses `IsPackOf`, which requires the
messages to be the single-space joins of a partition of `lines` into
consecutive non-empty groups.
-/
def ValidPack (lines : List String) (m : Nat) (msgs : List String) : Prop :=
  (∀ msg ∈ msgs, msg.length ≤ m) ∧ (∀ msg ∈ msgs, msg ≠ "")

/-
theorem pack_optimal : ∀ lines m, m > 0 → (∀ line ∈ lines, line.length ≤ m) →
    ∀ msgs, ValidPack lines m msgs → msgs.length ≥ (pack lines m).length := by
  sorry
-/

-- The empty list is a `ValidPack` of `["a"]`, refuting the statement above.
theorem pack_optimal_counterexample :
    ¬ (∀ lines m, m > 0 → (∀ line ∈ lines, line.length ≤ m) →
        ∀ msgs, ValidPack lines m msgs → msgs.length ≥ (pack lines m).length) := by
  intro h
  have hlines : ∀ line ∈ ["a"], line.length ≤ 1 := by
    intro line hl; simp at hl; subst hl; decide
  have hvalid : ValidPack ["a"] 1 [] := ⟨by simp, by simp⟩
  have := h ["a"] 1 (by omega) hlines [] hvalid
  have hpack : pack ["a"] 1 = ["a"] := by decide
  rw [hpack] at this
  simp at this

-- Single-space join of a group of lines, starting from accumulator `b`.
def joinFrom (b : String) (g : List String) : String :=
  g.foldl (fun a x => a ++ " " ++ x) b

def joinGroup : List String → String
  | [] => ""
  | x :: xs => joinFrom x xs

/-- `msgs` is a legal packing of `lines`: the single-space joins of a
partition of `lines` into consecutive non-empty groups, each within the
budget `m`. -/
def IsPackOf (lines : List String) (m : Nat) (msgs : List String) : Prop :=
  ∃ gs : List (List String), gs.flatten = lines ∧ (∀ g ∈ gs, g ≠ []) ∧
    (∀ g ∈ gs, (joinGroup g).length ≤ m) ∧ msgs = gs.map joinGroup

-- Number of further lines the greedy loop absorbs into accumulator `b`.
def gStep (b : String) (lines : List String) (m : Nat) : Nat :=
  match lines with
  | [] => 0
  | l :: rest => if b.length + 1 + l.length ≤ m then 1 + gStep (b ++ " " ++ l) rest m else 0

-- Size of the first greedy group.
def fgl (lines : List String) (m : Nat) : Nat :=
  match lines with
  | [] => 0
  | l :: rest => 1 + gStep l rest m

theorem joinFrom_length_ge : ∀ (g : List String) (b : String), b.length ≤ (joinFrom b g).length := by
  intro g
  induction g with
  | nil => intro b; simp [joinFrom]
  | cons x xs ih =>
      intro b
      have h1 := ih (b ++ " " ++ x)
      have h2 : (b ++ " " ++ x).length = b.length + 1 + x.length := sjoin_length b x
      have : joinFrom b (x :: xs) = joinFrom (b ++ " " ++ x) xs := by
        simp [joinFrom]
      rw [this]
      omega

-- Greedy absorbs every group that fits.
theorem gStep_absorbs : ∀ (g : List String) (b : String) (suffix : List String) (m : Nat),
    (joinFrom b g).length ≤ m → g.length ≤ gStep b (g ++ suffix) m := by
  intro g
  induction g with
  | nil => intro b suffix m _; simp
  | cons y g' ih =>
      intro b suffix m hfit
      have hstep : joinFrom b (y :: g') = joinFrom (b ++ " " ++ y) g' := by
        simp [joinFrom]
      rw [hstep] at hfit
      have hb : (b ++ " " ++ y).length ≤ m :=
        Nat.le_trans (joinFrom_length_ge g' (b ++ " " ++ y)) hfit
      have hb' : b.length + 1 + y.length ≤ m := by
        rw [sjoin_length] at hb; exact hb
      have hrec := ih (b ++ " " ++ y) suffix m hfit
      show (y :: g').length ≤ gStep b (y :: (g' ++ suffix)) m
      rw [gStep, if_pos hb']
      simp only [List.length_cons]
      omega

-- A longer accumulator absorbs no more lines than a shorter one.
theorem gStep_mono_buf : ∀ (lines : List String) (b1 b2 : String) (m : Nat),
    b1.length ≤ b2.length → gStep b2 lines m ≤ gStep b1 lines m := by
  intro lines
  induction lines with
  | nil => intro b1 b2 m _; simp [gStep]
  | cons l rest ih =>
      intro b1 b2 m hle
      by_cases h2 : b2.length + 1 + l.length ≤ m
      · have h1 : b1.length + 1 + l.length ≤ m := by omega
        rw [gStep, if_pos h2, gStep, if_pos h1]
        have hlen : (b1 ++ " " ++ l).length ≤ (b2 ++ " " ++ l).length := by
          rw [sjoin_length, sjoin_length]; omega
        have := ih (b1 ++ " " ++ l) (b2 ++ " " ++ l) m hlen
        omega
      · rw [gStep, if_neg h2]
        omega

-- One greedy message, then the greedy pack of what is left.
theorem packWith_len_step : ∀ (lines : List String) (m : Nat) (b : String),
    (∀ l ∈ lines, l ≠ "") →
    (packWith (some b) lines m).length
      = 1 + (packWith none (lines.drop (gStep b lines m)) m).length := by
  intro lines
  induction lines with
  | nil => intro m b _; simp [packWith, gStep]
  | cons line rest ih =>
      intro m b hne
      have hline : line ≠ "" := hne line (by simp)
      have hrest : ∀ l ∈ rest, l ≠ "" := fun l hl => hne l (by simp [hl])
      by_cases hfit : b.length + 1 + line.length ≤ m
      · have h1 : packWith (some b) (line :: rest) m
            = packWith (some (b ++ " " ++ line)) rest m := by
          simp [packWith, hline, hfit]
        have h2 : gStep b (line :: rest) m = 1 + gStep (b ++ " " ++ line) rest m := by
          rw [gStep, if_pos hfit]
        have h3 : List.drop (1 + gStep (b ++ " " ++ line) rest m) (line :: rest)
            = List.drop (gStep (b ++ " " ++ line) rest m) rest := by
          rw [Nat.add_comm]
          simp
        rw [h1, h2, h3, ih m (b ++ " " ++ line) hrest]
      · have h1 : packWith (some b) (line :: rest) m
            = b :: packWith (some line) rest m := by
          simp [packWith, hline, hfit]
        have h2 : gStep b (line :: rest) m = 0 := by
          rw [gStep, if_neg hfit]
        have h3 : packWith none (line :: rest) m = packWith (some line) rest m := by
          simp [packWith, hline]
        rw [h1, h2]
        simp only [List.drop_zero]
        rw [h3]
        simp
        omega

theorem pack_len_step : ∀ (lines : List String) (m : Nat), lines ≠ [] →
    (∀ l ∈ lines, l ≠ "") →
    (pack lines m).length = 1 + (pack (lines.drop (fgl lines m)) m).length := by
  intro lines m hne hlines
  cases lines with
  | nil => exact absurd rfl hne
  | cons l rest =>
      have hl : l ≠ "" := hlines l (by simp)
      have hrest : ∀ x ∈ rest, x ≠ "" := fun x hx => hlines x (by simp [hx])
      have h1 : pack (l :: rest) m = packWith (some l) rest m := by
        simp [pack, packWith, hl]
      have h2 : fgl (l :: rest) m = 1 + gStep l rest m := by rw [fgl]
      have h3 : List.drop (1 + gStep l rest m) (l :: rest) = List.drop (gStep l rest m) rest := by
        rw [Nat.add_comm]
        simp
      rw [h1, h2, h3, packWith_len_step rest m l hrest]
      simp [pack]

-- Dropping the head cannot make the greedy first group start later.
theorem gStep_le_fgl : ∀ (x : String) (rest : List String) (m : Nat),
    gStep x rest m ≤ fgl rest m := by
  intro x rest m
  cases rest with
  | nil => simp [gStep, fgl]
  | cons y t =>
      by_cases hfit : x.length + 1 + y.length ≤ m
      · rw [gStep, if_pos hfit, fgl]
        have hlen : y.length ≤ (x ++ " " ++ y).length := by
          rw [sjoin_length]; omega
        have := gStep_mono_buf t y (x ++ " " ++ y) m hlen
        omega
      · rw [gStep, if_neg hfit]
        omega

-- Greedy on a suffix never needs more messages than greedy on the whole.
theorem pack_len_drop_le_aux : ∀ (n : Nat) (lines : List String) (m d : Nat),
    lines.length ≤ n → (∀ l ∈ lines, l ≠ "") →
    (pack (lines.drop d) m).length ≤ (pack lines m).length := by
  intro n
  induction n with
  | zero =>
      intro lines m d hlen _
      have : lines = [] := List.eq_nil_of_length_eq_zero (by omega)
      subst this
      simp
  | succ n ih =>
      intro lines m d hlen hne
      cases d with
      | zero => simp
      | succ d =>
          cases lines with
          | nil => simp
          | cons x rest =>
              have hrest : ∀ l ∈ rest, l ≠ "" := fun l hl => hne l (by simp [hl])
              have hrlen : rest.length ≤ n := by
                simp at hlen; omega
              have hA : (pack (rest.drop d) m).length ≤ (pack rest m).length :=
                ih rest m d hrlen hrest
              have hB : (pack rest m).length ≤ (pack (x :: rest) m).length := by
                by_cases hrnil : rest = []
                · subst hrnil; simp [pack, packWith]
                · have hk := pack_len_step (x :: rest) m (by simp) hne
                  have hk' := pack_len_step rest m hrnil hrest
                  have hdrop1 : (x :: rest).drop (fgl (x :: rest) m)
                      = rest.drop (gStep x rest m) := by
                    rw [fgl, Nat.add_comm]
                    simp
                  have hle : gStep x rest m ≤ fgl rest m := gStep_le_fgl x rest m
                  have hdrop2 : rest.drop (fgl rest m)
                      = (rest.drop (gStep x rest m)).drop (fgl rest m - gStep x rest m) := by
                    rw [List.drop_drop]
                    congr 1
                    omega
                  have hsub : (pack (rest.drop (fgl rest m)) m).length
                      ≤ (pack (rest.drop (gStep x rest m)) m).length := by
                    rw [hdrop2]
                    refine ih (rest.drop (gStep x rest m)) m _ ?_ ?_
                    · have hdl : (rest.drop (gStep x rest m)).length ≤ rest.length := by simp
                      omega
                    · intro l hl
                      exact hrest l (List.mem_of_mem_drop hl)
                  rw [hk, hk', hdrop1]
                  omega
              have hgoal : (x :: rest).drop (d + 1) = rest.drop d := by simp
              rw [hgoal]
              omega

theorem pack_len_drop_le : ∀ (lines : List String) (m d : Nat),
    (∀ l ∈ lines, l ≠ "") →
    (pack (lines.drop d) m).length ≤ (pack lines m).length := by
  intro lines m d hne
  exact pack_len_drop_le_aux lines.length lines m d (Nat.le_refl _) hne

theorem drop_append_ge : ∀ {α} (g t : List α) (k : Nat), g.length ≤ k →
    (g ++ t).drop k = t.drop (k - g.length) := by
  intro α g
  induction g with
  | nil => intro t k _; simp
  | cons x xs ih =>
      intro t k hk
      cases k with
      | zero => simp at hk
      | succ k =>
          have hk' : xs.length ≤ k := by simp at hk; omega
          simp only [List.cons_append, List.drop_succ_cons]
          rw [ih t k hk']
          simp

-- Optimality, in terms of an explicit grouping of the lines.
theorem pack_optimal_groups : ∀ (gs : List (List String)) (m : Nat),
    (∀ line ∈ gs.flatten, line ≠ "") → (∀ g ∈ gs, g ≠ []) →
    (∀ g ∈ gs, (joinGroup g).length ≤ m) →
    (pack gs.flatten m).length ≤ gs.length := by
  intro gs
  induction gs with
  | nil => intro m _ _ _; simp [pack, packWith]
  | cons g gs' ih =>
      intro m hnb hgne hgfit
      have hgne0 : g ≠ [] := hgne g (by simp)
      have hgfit0 : (joinGroup g).length ≤ m := hgfit g (by simp)
      have hgne' : ∀ h ∈ gs', h ≠ [] := fun h hh => hgne h (by simp [hh])
      have hgfit' : ∀ h ∈ gs', (joinGroup h).length ≤ m := fun h hh => hgfit h (by simp [hh])
      obtain ⟨l, g0, rfl⟩ : ∃ l g0, g = l :: g0 := by
        cases g with
        | nil => exact absurd rfl hgne0
        | cons a b => exact ⟨a, b, rfl⟩
      have hflat : ((l :: g0) :: gs').flatten = (l :: g0) ++ gs'.flatten := by simp
      rw [hflat] at hnb ⊢
      have hnbr : ∀ x ∈ gs'.flatten, x ≠ "" := fun x hx =>
        hnb x (List.mem_append_right (l :: g0) hx)
      have hcons : (l :: g0) ++ gs'.flatten = l :: (g0 ++ gs'.flatten) := by simp
      have hstep := pack_len_step ((l :: g0) ++ gs'.flatten) m (by simp) hnb
      have habs : g0.length ≤ gStep l (g0 ++ gs'.flatten) m := by
        have hj : (joinFrom l g0).length ≤ m := by simpa [joinGroup] using hgfit0
        exact gStep_absorbs g0 l gs'.flatten m hj
      have hfgl : (l :: g0).length ≤ fgl ((l :: g0) ++ gs'.flatten) m := by
        rw [hcons, fgl]
        simp only [List.length_cons]
        omega
      have hdrop : ((l :: g0) ++ gs'.flatten).drop (fgl ((l :: g0) ++ gs'.flatten) m)
          = gs'.flatten.drop (fgl ((l :: g0) ++ gs'.flatten) m - (l :: g0).length) :=
        drop_append_ge (l :: g0) gs'.flatten _ hfgl
      have hmono := pack_len_drop_le gs'.flatten m
        (fgl ((l :: g0) ++ gs'.flatten) m - (l :: g0).length) hnbr
      have hih := ih m hnbr hgne' hgfit'
      have hcard : ((l :: g0) :: gs').length = gs'.length + 1 := by simp
      rw [hstep, hdrop, hcard]
      omega

/--
Optimality (corrected): the greedy pack uses the fewest messages among
all legal packings of the same lines under the `≤ m` budget, where a
legal packing (`IsPackOf`) joins consecutive non-empty groups of lines
with single spaces.  Blank-free input is required (a blank line flushes
the greedy accumulator).
-/
theorem pack_optimal_correct : ∀ (lines : List String) (m : Nat),
    (∀ line ∈ lines, line ≠ "") →
    ∀ msgs, IsPackOf lines m msgs → (pack lines m).length ≤ msgs.length := by
  intro lines m hne msgs ⟨gs, hflat, hgne, hgfit, hmsgs⟩
  subst hmsgs
  subst hflat
  simpa using pack_optimal_groups gs m hne hgne hgfit

-- ── The greedy pack is itself a legal pack ────────────────────────

-- The greedy loop emits exactly the join of the lines it absorbed.
theorem packWith_step_str : ∀ (lines : List String) (m : Nat) (b : String),
    (∀ l ∈ lines, l ≠ "") →
    packWith (some b) lines m
      = joinFrom b (lines.take (gStep b lines m))
          :: packWith none (lines.drop (gStep b lines m)) m := by
  intro lines
  induction lines with
  | nil => intro m b _; simp [packWith, gStep, joinFrom]
  | cons line rest ih =>
      intro m b hne
      have hline : line ≠ "" := hne line (by simp)
      have hrest : ∀ l ∈ rest, l ≠ "" := fun l hl => hne l (by simp [hl])
      by_cases hfit : b.length + 1 + line.length ≤ m
      · have h1 : packWith (some b) (line :: rest) m
            = packWith (some (b ++ " " ++ line)) rest m := by
          simp [packWith, hline, hfit]
        have h2 : gStep b (line :: rest) m = 1 + gStep (b ++ " " ++ line) rest m := by
          rw [gStep, if_pos hfit]
        have htake : (line :: rest).take (1 + gStep (b ++ " " ++ line) rest m)
            = line :: rest.take (gStep (b ++ " " ++ line) rest m) := by
          rw [Nat.add_comm]; simp
        have hdrop : (line :: rest).drop (1 + gStep (b ++ " " ++ line) rest m)
            = rest.drop (gStep (b ++ " " ++ line) rest m) := by
          rw [Nat.add_comm]; simp
        have hjoin : joinFrom b (line :: rest.take (gStep (b ++ " " ++ line) rest m))
            = joinFrom (b ++ " " ++ line) (rest.take (gStep (b ++ " " ++ line) rest m)) := by
          simp [joinFrom]
        rw [h1, h2, htake, hdrop, hjoin, ih m (b ++ " " ++ line) hrest]
      · have h1 : packWith (some b) (line :: rest) m
            = b :: packWith (some line) rest m := by
          simp [packWith, hline, hfit]
        have h2 : gStep b (line :: rest) m = 0 := by
          rw [gStep, if_neg hfit]
        have h3 : packWith none (line :: rest) m = packWith (some line) rest m := by
          simp [packWith, hline]
        rw [h1, h2]
        simp only [List.take_zero, List.drop_zero, joinFrom, List.foldl_nil]
        rw [h3]

-- The emitted message respects the budget.
theorem gStep_take_fits : ∀ (lines : List String) (b : String) (m : Nat), b.length ≤ m →
    (joinFrom b (lines.take (gStep b lines m))).length ≤ m := by
  intro lines
  induction lines with
  | nil => intro b m hb; simpa [gStep, joinFrom] using hb
  | cons line rest ih =>
      intro b m hb
      by_cases hfit : b.length + 1 + line.length ≤ m
      · have h2 : gStep b (line :: rest) m = 1 + gStep (b ++ " " ++ line) rest m := by
          rw [gStep, if_pos hfit]
        have htake : (line :: rest).take (1 + gStep (b ++ " " ++ line) rest m)
            = line :: rest.take (gStep (b ++ " " ++ line) rest m) := by
          rw [Nat.add_comm]; simp
        have hjoin : joinFrom b (line :: rest.take (gStep (b ++ " " ++ line) rest m))
            = joinFrom (b ++ " " ++ line) (rest.take (gStep (b ++ " " ++ line) rest m)) := by
          simp [joinFrom]
        have hb' : (b ++ " " ++ line).length ≤ m := by rw [sjoin_length]; omega
        rw [h2, htake, hjoin]
        exact ih (b ++ " " ++ line) m hb'
      · have h2 : gStep b (line :: rest) m = 0 := by rw [gStep, if_neg hfit]
        rw [h2]
        simpa [joinFrom] using hb

/-- The greedy pack is a legal pack of its input, so `pack_optimal_correct`
really does say that greedy attains the minimum message count. -/
theorem pack_isPackOf_aux : ∀ (n : Nat) (lines : List String) (m : Nat), lines.length ≤ n →
    (∀ l ∈ lines, l ≠ "") → (∀ l ∈ lines, l.length ≤ m) →
    IsPackOf lines m (pack lines m) := by
  intro n
  induction n with
  | zero =>
      intro lines m hlen _ _
      have : lines = [] := List.eq_nil_of_length_eq_zero (by omega)
      subst this
      exact ⟨[], by simp, by simp, by simp, by simp [pack, packWith]⟩
  | succ n ih =>
      intro lines m hlen hne hfit
      cases lines with
      | nil => exact ⟨[], by simp, by simp, by simp, by simp [pack, packWith]⟩
      | cons l rest =>
          have hl : l ≠ "" := hne l (by simp)
          have hlfit : l.length ≤ m := hfit l (by simp)
          have hrne : ∀ x ∈ rest, x ≠ "" := fun x hx => hne x (by simp [hx])
          have hrfit : ∀ x ∈ rest, x.length ≤ m := fun x hx => hfit x (by simp [hx])
          have hpack : pack (l :: rest) m
              = joinFrom l (rest.take (gStep l rest m))
                  :: packWith none (rest.drop (gStep l rest m)) m := by
            have h1 : pack (l :: rest) m = packWith (some l) rest m := by
              simp [pack, packWith, hl]
            rw [h1, packWith_step_str rest m l hrne]
          have hdlen : (rest.drop (gStep l rest m)).length ≤ n := by
            have hle : (rest.drop (gStep l rest m)).length ≤ rest.length := by simp
            simp at hlen
            omega
          have hdne : ∀ x ∈ rest.drop (gStep l rest m), x ≠ "" :=
            fun x hx => hrne x (List.mem_of_mem_drop hx)
          have hdfit : ∀ x ∈ rest.drop (gStep l rest m), x.length ≤ m :=
            fun x hx => hrfit x (List.mem_of_mem_drop hx)
          obtain ⟨gs', hflat', hne', hfit', hmsgs'⟩ :=
            ih (rest.drop (gStep l rest m)) m hdlen hdne hdfit
          refine ⟨(l :: rest.take (gStep l rest m)) :: gs', ?_, ?_, ?_, ?_⟩
          · simp only [List.flatten_cons, hflat']
            simp
          · intro g hg
            rcases List.mem_cons.1 hg with rfl | hg'
            · simp
            · exact hne' g hg'
          · intro g hg
            rcases List.mem_cons.1 hg with rfl | hg'
            · have := gStep_take_fits rest l m hlfit
              simpa [joinGroup] using this
            · exact hfit' g hg'
          · rw [hpack]
            simp only [List.map_cons, joinGroup]
            rw [← hmsgs']
            rfl

theorem pack_isPackOf : ∀ (lines : List String) (m : Nat),
    (∀ l ∈ lines, l ≠ "") → (∀ l ∈ lines, l.length ≤ m) →
    IsPackOf lines m (pack lines m) := by
  intro lines m hne hfit
  exact pack_isPackOf_aux lines.length lines m (Nat.le_refl _) hne hfit

-- ── Batcher (messageBatcher.ts) ───────────────────────────────────

-- flushAll snapshots-and-clears each queue, so the flush observes a
-- FIFO batch and the queue is empty afterwards.
def flushQueue (q : List String) : List String × List String := (q, [])

theorem flush_snapshot : ∀ q, (flushQueue q).1 = q ∧ (flushQueue q).2 = [] := by
  intro q
  simp [flushQueue]

-- SORRY (Aristotle): enqueue is append — order within a key's batch is
-- preserved end-to-end from send to render (no reorder).
theorem enqueue_append_dropLast : ∀ (q : List String) (m : String), (q ++ [m]).dropLast = q := by
  intro q m
  simp

end IrcFiber.Splitter
