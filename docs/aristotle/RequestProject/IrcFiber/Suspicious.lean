import Std

namespace IrcFiber.Suspicious

/-!
Suspicious-port / suspicious-hostname predicates, mirroring
`frontend/src/lib/suspiciousConnection.ts` and the `looksLocal`
block of `frontend/src/lib/connectionWarnings.ts`.

FINDING (verified below): the RFC 1918 coverage in `looksLocal` is
incomplete — 172.30.0.0/16 and 172.31.0.0/16 are private per RFC 1918
but are NOT flagged by the string-prefix checks. See
`rfc1918_gap_172_30` and `rfc1918_gap_172_31`.
-/

-- ── Ports ─────────────────────────────────────────────────────────

def PLAIN : List Nat := [6667, 6660, 6661, 6662, 6663, 6664, 6665, 6666, 6668, 6669, 7000]
def TLS : List Nat := [6697, 6690, 6691, 6692, 6693, 6694, 6695, 6696, 6698, 6699]

-- The two port families are disjoint, so a port can never be both
-- "plain-IRC" and "IRC-over-TLS" (no ambiguous warnings).
theorem plain_tls_disjoint : ∀ p, p ∈ PLAIN → p ∉ TLS := by
  intro p hp
  simp [PLAIN] at hp
  rcases hp with rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl
  all_goals decide

-- isSuspiciousPort spec: SSL on a plain port, or plain on a TLS port.
def suspiciousPort (port : Nat) (isSSL : Bool) : Bool :=
  if isSSL then port ∈ PLAIN else port ∈ TLS

-- The warning is produced exactly when the port pairing is suspicious.
def warn (port : Nat) (isSSL : Bool) : Option String :=
  if suspiciousPort port isSSL then some "suspicious port" else none

theorem warn_iff_suspicious : ∀ port isSSL, (warn port isSSL).isSome ↔ suspiciousPort port isSSL := by
  intro port isSSL
  by_cases h : suspiciousPort port isSSL
  · simp [warn, h]
  · simp [warn, h]

-- ── RFC 1918 ──────────────────────────────────────────────────────

-- Numeric, RFC-correct predicate: 10.0.0.0/8, 172.16.0.0/12,
-- 192.168.0.0/16 (plus loopback 127/8 which the code also flags).
def isPrivateRfc1918 (a b : Nat) : Prop :=
  a = 10 ∨ (a = 172 ∧ 16 ≤ b ∧ b ≤ 31) ∨ (a = 192 ∧ b = 168) ∨ a = 127

-- What the string-prefix checks in connectionWarnings.ts actually
-- cover (second octet only; the code tests `lower.startsWith("172.2")`
-- plus /^172\\.2[0-9]\\./ which yields 172.20-172.29).
def codeFlags (a b : Nat) : Prop :=
  a = 10 ∨ (a = 172 ∧ 16 ≤ b ∧ b ≤ 19) ∨ (a = 172 ∧ 20 ≤ b ∧ b ≤ 29)
    ∨ (a = 192 ∧ b = 168) ∨ a = 127

-- Soundness: everything the code flags is either RFC 1918 or loopback.
theorem code_flags_sound : ∀ a b, codeFlags a b → isPrivateRfc1918 a b := by
  intro a b h
  unfold codeFlags at h
  rcases h with h10 | h172a | h172b | h192 | h127
  · unfold isPrivateRfc1918; exact Or.inl h10
  · unfold isPrivateRfc1918; exact Or.inr (Or.inl ⟨h172a.1, ⟨h172a.2.1, by omega⟩⟩)
  · unfold isPrivateRfc1918; exact Or.inr (Or.inl ⟨h172b.1, ⟨by omega, by omega⟩⟩)
  · unfold isPrivateRfc1918; exact Or.inr (Or.inr (Or.inl h192))
  · unfold isPrivateRfc1918; exact Or.inr (Or.inr (Or.inr h127))

-- 172.30.0.0/16 is RFC 1918 (second octet in [16,31]).
theorem rfc1918_172_30 : isPrivateRfc1918 172 30 := by
  unfold isPrivateRfc1918
  right; left; constructor
  · rfl
  · constructor <;> omega

-- ...but the code's prefix checks do NOT flag it.
theorem not_flagged_172_30 : ¬ codeFlags 172 30 := by
  intro h
  unfold codeFlags at h
  rcases h with h1 | h2 | h3 | h4 | h5 <;> omega

-- Completeness failure: 172.30.0.0/16 is RFC 1918 but not flagged.
theorem rfc1918_gap_172_30 : isPrivateRfc1918 172 30 ∧ ¬ codeFlags 172 30 := by
  exact ⟨rfc1918_172_30, not_flagged_172_30⟩

-- 172.31.0.0/16 is RFC 1918 ...
theorem rfc1918_172_31 : isPrivateRfc1918 172 31 := by
  unfold isPrivateRfc1918
  right; left; constructor
  · rfl
  · constructor <;> omega

-- ...but is NOT flagged either.
theorem not_flagged_172_31 : ¬ codeFlags 172 31 := by
  intro h
  unfold codeFlags at h
  rcases h with h1 | h2 | h3 | h4 | h5 <;> omega

-- Completeness failure: 172.31.0.0/16 is RFC 1918 but not flagged.
theorem rfc1918_gap_172_31 : isPrivateRfc1918 172 31 ∧ ¬ codeFlags 172 31 := by
  exact ⟨rfc1918_172_31, not_flagged_172_31⟩

-- The 172.16/12 range IS fully covered through 172.29 (spot checks).
theorem covered_172_16 : codeFlags 172 16 := by
  unfold codeFlags; right; left; constructor
  · rfl
  · constructor <;> omega
theorem covered_172_19 : codeFlags 172 19 := by
  unfold codeFlags; right; left; constructor
  · rfl
  · constructor <;> omega
theorem covered_172_20 : codeFlags 172 20 := by
  unfold codeFlags
  right; right; left; constructor
  · rfl
  · constructor <;> omega
theorem covered_172_29 : codeFlags 172 29 := by
  unfold codeFlags
  right; right; left; constructor
  · rfl
  · constructor <;> omega

-- ── Hostname shape ────────────────────────────────────────────────

-- isSuspiciousHostname ordering: leading dot, then trailing dot, then
-- no-dot-no-colon. First match wins; otherwise not suspicious.
def suspiciousHostname (h : String) : Option String :=
  if h.startsWith "." then some "leading-dot"
  else if h.endsWith "." then some "trailing-dot"
  else if ¬ h.contains '.' ∧ ¬ h.contains ':' then some "no-label"
  else none

theorem host_leading_dot : ∀ h, h.startsWith "." → suspiciousHostname h = some "leading-dot" := by
  intro h hd
  simp [suspiciousHostname, hd]

theorem host_trailing_dot : ∀ h, ¬ h.startsWith "." → h.endsWith "." → suspiciousHostname h = some "trailing-dot" := by
  intro h hnd htd
  simp [suspiciousHostname, hnd, htd]

theorem host_no_label : ∀ h,
    ¬ h.startsWith "." → ¬ h.endsWith "." → ¬ h.contains '.' → ¬ h.contains ':' →
    suspiciousHostname h = some "no-label" := by
  intro h hnd htd hdot hcolon
  simp [suspiciousHostname, hnd, htd, hdot, hcolon]

theorem host_clean : ∀ h,
    ¬ h.startsWith "." → ¬ h.endsWith "." → h.contains '.' ∨ h.contains ':' →
    suspiciousHostname h = none := by
  intro h hnd htd hdotcolon
  unfold suspiciousHostname
  simp [hnd, htd]
  by_cases hc : h.contains '.' = true
  · simp [hc]
  · by_cases hc2 : h.contains ':' = true
    · simp [hc, hc2]
    · exfalso
      rcases hdotcolon with hd | hcol
      · exact hc hd
      · exact hc2 hcol

-- The discriminator is a total function: every hostname maps to one
-- of the four outcomes.
theorem host_total : ∀ h, suspiciousHostname h = none
    ∨ suspiciousHostname h = some "leading-dot"
    ∨ suspiciousHostname h = some "trailing-dot"
    ∨ suspiciousHostname h = some "no-label" := by
  intro h
  unfold suspiciousHostname
  by_cases h1 : h.startsWith "." = true
  · right; left; simp [h1]
  · by_cases h2 : h.endsWith "." = true
    · right; right; left; simp [h1, h2]
    · by_cases hc : h.contains '.' = true
      · left; simp [h1, h2, hc]
      · by_cases hc2 : h.contains ':' = true
        · left; simp [h1, h2, hc, hc2]
        · right; right; right; simp [h1, h2, hc, hc2]

end IrcFiber.Suspicious
