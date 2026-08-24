import Std

namespace IrcFiber.Ordinal

/-!
English ordinal suffixes, mirroring `ordinalSuffix` in
`frontend/src/lib/connectionWarnings.ts`:

    function ordinalSuffix(n) {
      const v = n % 100;
      if (v >= 11 && v <= 13) return 'th';
      switch (n % 10) {
        case 1: return 'st';  case 2: return 'nd';  case 3: return 'rd';
        default: return 'th';
      }
    }

Encoding: 0 = "st", 1 = "nd", 2 = "rd", 3 = "th".
-/

def suffix (n : Nat) : Nat :=
  let v := n % 100
  if 11 ≤ v ∧ v ≤ 13 then 3
  else match n % 10 with
    | 1 => 0
    | 2 => 1
    | 3 => 2
    | _ => 3

-- The teens rule: 11, 12, 13 are always "th".
theorem suffix_teens : ∀ n, 11 ≤ n % 100 → n % 100 ≤ 13 → suffix n = 3 := by
  intro n h1 h2
  simp [suffix, h1, h2]

theorem suffix_one_not_teens : ∀ n, n % 100 ≠ 11 → n % 100 ≠ 12 → n % 100 ≠ 13 → n % 10 = 1 → suffix n = 0 := by
  intro n h11 h12 h13 h1
  unfold suffix
  by_cases h : 11 ≤ n % 100 ∧ n % 100 ≤ 13
  · exfalso; omega
  · simp [h, h1]

theorem suffix_two_not_teens : ∀ n, n % 100 ≠ 11 → n % 100 ≠ 12 → n % 100 ≠ 13 → n % 10 = 2 → suffix n = 1 := by
  intro n h11 h12 h13 h2
  unfold suffix
  by_cases h : 11 ≤ n % 100 ∧ n % 100 ≤ 13
  · exfalso; omega
  · simp [h, h2]

theorem suffix_three_not_teens : ∀ n, n % 100 ≠ 11 → n % 100 ≠ 12 → n % 100 ≠ 13 → n % 10 = 3 → suffix n = 2 := by
  intro n h11 h12 h13 h3
  unfold suffix
  by_cases h : 11 ≤ n % 100 ∧ n % 100 ≤ 13
  · exfalso; omega
  · simp [h, h3]

theorem suffix_other_not_teens : ∀ n,
    n % 100 ≠ 11 → n % 100 ≠ 12 → n % 100 ≠ 13 →
    n % 10 ≠ 1 → n % 10 ≠ 2 → n % 10 ≠ 3 → suffix n = 3 := by
  intro n h11 h12 h13 h1 h2 h3
  unfold suffix
  by_cases h : 11 ≤ n % 100 ∧ n % 100 ≤ 13
  · exfalso; omega
  · simp [h, h1, h2, h3]

-- Concrete sanity checks (mirrors ConnectionStatus.test.ts expectations).
theorem check_1st : suffix 1 = 0 := by native_decide
theorem check_2nd : suffix 2 = 1 := by native_decide
theorem check_3rd : suffix 3 = 2 := by native_decide
theorem check_4th : suffix 4 = 3 := by native_decide
theorem check_11th : suffix 11 = 3 := by native_decide
theorem check_12th : suffix 12 = 3 := by native_decide
theorem check_13th : suffix 13 = 3 := by native_decide
theorem check_21st : suffix 21 = 0 := by native_decide
theorem check_22nd : suffix 22 = 1 := by native_decide
theorem check_23rd : suffix 23 = 2 := by native_decide
theorem check_111th : suffix 111 = 3 := by native_decide
theorem check_112th : suffix 112 = 3 := by native_decide
theorem check_113th : suffix 113 = 3 := by native_decide
theorem check_121st : suffix 121 = 0 := by native_decide

end IrcFiber.Ordinal
