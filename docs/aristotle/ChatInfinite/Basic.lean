import Mathlib

/-!
# Message buffers, deduplicated prepend, and cursor pagination

This file models the *data* half of IRC Fiber's reverse infinite scroll:

* a chat buffer is a list of messages ordered **oldest first**, keyed by a
  strictly increasing event id (`eid`), which is the primary component of the
  pagination cursor (the timestamp is only a fallback and is not modelled: any
  total order on messages can play the role of `eid`);
* `prependDedup` is the store operation `prependMessages`: a freshly fetched
  older page is deduplicated against the current buffer and glued in front;
* `pageBefore` is the backend cursor query
  `GET …/messages?beforeid=<cursor>&count=<count>`: the *newest* `count`
  messages strictly older than the cursor.

The theorems proved here are the pagination-correctness requirements:
duplicate-freedom, idempotence of re-delivering the same page (no
double-render of a batch), strict cursor progress (no phantom stall),
absence of gaps between consecutive pages, termination of paging, and
stability of the render key of already-rendered rows under prepends.
-/

namespace ChatInfinite

/-- A chat message, identified by its event id.  In the real client the
identity used for deduplication is `eid` with `msgid` as fallback; both are
modelled by this single total-order key. -/
structure Msg where
  eid : Nat
  deriving DecidableEq, Repr

/-- A rendered/stored buffer: oldest message first, newest last. -/
abbrev Buf := List Msg

/-- The event ids of a buffer. -/
def eids (l : Buf) : List Nat := l.map Msg.eid

/-- A buffer is *ordered* when event ids strictly increase from oldest to
newest.  This is the total-order invariant the cursor relies on. -/
def Ordered (l : Buf) : Prop := List.Pairwise (fun a b => a.eid < b.eid) l

theorem Ordered.nodup_eids {l : Buf} (h : Ordered l) : (eids l).Nodup := by
  exact List.pairwise_map.mpr (h.imp (fun hab => Nat.ne_of_lt hab))

theorem Ordered.sublist {l₁ l₂ : Buf} (hs : l₁.Sublist l₂) (h : Ordered l₂) :
    Ordered l₁ := List.Pairwise.sublist hs h

/-! ## Deduplicated prepend -/

/-- Drop from `page` every message whose `eid` already occurs in `old`. -/
def dedupAgainst (old page : Buf) : Buf :=
  page.filter (fun m => !old.any (fun o => o.eid == m.eid))

/-- Store operation `prependMessages`: glue an older page in front of the
current buffer, deduplicating by event id. -/
def prependDedup (old page : Buf) : Buf := dedupAgainst old page ++ old

theorem mem_dedupAgainst {old page : Buf} {m : Msg} :
    m ∈ dedupAgainst old page ↔ m ∈ page ∧ ∀ o ∈ old, o.eid ≠ m.eid := by
  simp [dedupAgainst, List.mem_filter]

/-- Nothing already in the buffer is lost by a prepend: no dropped messages. -/
theorem old_subset_prependDedup (old page : Buf) : ∀ m ∈ old, m ∈ prependDedup old page := by
  intro m hm; simp [prependDedup, hm]

/-- Every new message of the page that is not a duplicate is delivered. -/
theorem new_mem_prependDedup {old page : Buf} {m : Msg}
    (hm : m ∈ page) (hnew : ∀ o ∈ old, o.eid ≠ m.eid) : m ∈ prependDedup old page := by
  simp only [prependDedup, List.mem_append]
  exact Or.inl (mem_dedupAgainst.mpr ⟨hm, hnew⟩)

/-- **No duplicate keys after a prepend.**  If the buffer and the incoming page
are individually duplicate-free, so is the merged buffer. -/
theorem noDuplicatesAfterPrepend {old page : Buf}
    (hold : (eids old).Nodup) (hpage : (eids page).Nodup) :
    (eids (prependDedup old page)).Nodup := by
  have hsub : (eids (dedupAgainst old page)).Nodup := by
    refine List.Nodup.sublist ?_ hpage
    exact List.Sublist.map _ List.filter_sublist
  simp only [prependDedup, eids, List.map_append]
  refine List.Nodup.append hsub hold ?_
  intro x hx hxo
  simp only [List.mem_map] at hx hxo
  obtain ⟨m, hm, rfl⟩ := hx
  obtain ⟨o, ho, hoe⟩ := hxo
  exact (mem_dedupAgainst.mp hm).2 o ho hoe

/-- **No double-render of the same batch.**  Delivering the very same page a
second time (a duplicated network response, or a sentinel that fires twice)
leaves the buffer untouched. -/
theorem prependDedup_idempotent (old page : Buf) :
    prependDedup (prependDedup old page) page = prependDedup old page := by
  have h : dedupAgainst (prependDedup old page) page = [] := by
    rw [dedupAgainst, List.filter_eq_nil_iff]
    intro m hm
    have hex : ∃ o ∈ prependDedup old page, o.eid = m.eid := by
      by_cases hd : ∀ o ∈ old, o.eid ≠ m.eid
      · exact ⟨m, new_mem_prependDedup hm hd, rfl⟩
      · push_neg at hd
        obtain ⟨o, ho, hoe⟩ := hd
        exact ⟨o, old_subset_prependDedup old page o ho, hoe⟩
    obtain ⟨o, ho, hoe⟩ := hex
    simp only [Bool.not_eq_true', Bool.not_eq_false, List.any_eq_true, beq_iff_eq]
    exact ⟨o, ho, hoe⟩
  show dedupAgainst (prependDedup old page) page ++ prependDedup old page = prependDedup old page
  rw [h, List.nil_append]

/-- If the incoming page is strictly older than the whole buffer (the situation
created by cursor pagination), the merged buffer is still ordered. -/
theorem Ordered.prependDedup {old page : Buf} (hold : Ordered old) (hpage : Ordered page)
    (hsep : ∀ p ∈ page, ∀ o ∈ old, p.eid < o.eid) :
    Ordered (prependDedup old page) := by
  refine List.pairwise_append.mpr ⟨?_, hold, ?_⟩
  · exact Ordered.sublist List.filter_sublist hpage
  · intro a ha b hb
    exact hsep a (mem_dedupAgainst.mp ha).1 b hb

/-! ## Stable render keys -/

/-- The render key of a row: how many messages of the buffer are *newer* than
it.  Counting from the bottom (rather than from the top) is what makes the key
`base#absoluteIndex` stable while older history is prepended, so heavyweight
rows (ANSI art, images) are never recreated. -/
def newerCount (buf : Buf) (m : Msg) : Nat :=
  (buf.filter (fun x => decide (m.eid < x.eid))).length

/-- **Stable keys.**  Prepending a strictly older page does not change the
render key of any message already in the buffer. -/
theorem stableKeyUnchangedByPrepend {old page : Buf} {m : Msg} (hm : m ∈ old)
    (hsep : ∀ p ∈ page, ∀ o ∈ old, p.eid < o.eid) :
    newerCount (prependDedup old page) m = newerCount old m := by
  have h : (dedupAgainst old page).filter (fun x => decide (m.eid < x.eid)) = [] := by
    rw [List.filter_eq_nil_iff]
    intro p hp
    have := hsep p (mem_dedupAgainst.mp hp).1 m hm
    simp; omega
  simp [newerCount, prependDedup, List.filter_append, h]

/-! ## Cursor pagination -/

/-- The last `n` elements of a list. -/
def lastN (n : Nat) (l : List Msg) : List Msg := l.drop (l.length - n)

/-- All messages of the history strictly older than the cursor. -/
def olderThan (c : Nat) (hist : Buf) : Buf := hist.filter (fun m => decide (m.eid < c))

/-- The backend query `?beforeid=c&count=n`: the newest `n` messages strictly
older than the cursor `c`. -/
def pageBefore (hist : Buf) (c n : Nat) : Buf := lastN n (olderThan c hist)

/-- `hasMore` as reported by the backend envelope. -/
def hasMoreBefore (hist : Buf) (c : Nat) : Bool := hist.any (fun m => decide (m.eid < c))

theorem pageBefore_sublist (hist : Buf) (c n : Nat) :
    (pageBefore hist c n).Sublist hist :=
  (List.drop_sublist _ _).trans List.filter_sublist

theorem mem_pageBefore_imp {hist : Buf} {c n : Nat} {m : Msg} (h : m ∈ pageBefore hist c n) :
    m ∈ hist ∧ m.eid < c := by
  have h' : m ∈ olderThan c hist := (List.drop_sublist _ _).mem h
  simpa [olderThan, List.mem_filter] using h'

/-- **Strict cursor progress.**  Every message of the returned page is strictly
older than the cursor, hence the next cursor (the earliest eid of the page) is
strictly smaller: the cursor can never stall on a phantom id. -/
theorem cursorStrictlyAdvances {hist : Buf} {c n : Nat} {q : Msg}
    (hq : q ∈ pageBefore hist c n) : q.eid < c :=
  (mem_pageBefore_imp hq).2

/-- **No gaps.**  Every message of the history lying between the new cursor
(any message of the page, in particular its earliest one) and the old cursor is
contained in the page: consecutive pages tile the history without holes. -/
theorem noGaps {hist : Buf} {c n : Nat} {q m : Msg} (hord : Ordered hist)
    (hq : q ∈ pageBefore hist c n) (hm : m ∈ hist) (hmc : m.eid < c) (hqm : q.eid ≤ m.eid) :
    m ∈ pageBefore hist c n := by
  set F := olderThan c hist with hF
  have hmF : m ∈ F := by simp [hF, olderThan, List.mem_filter, hm, hmc]
  set j := F.length - n with hj
  have hsplit : F.take j ++ F.drop j = F := List.take_append_drop j F
  have hordF : Ordered F := Ordered.sublist List.filter_sublist hord
  by_contra hcon
  have hmtake : m ∈ F.take j := by
    have : m ∈ F.take j ++ F.drop j := by rw [hsplit]; exact hmF
    rcases List.mem_append.mp this with h | h
    · exact h
    · exact absurd h hcon
  have hpair := List.pairwise_append.mp (hsplit ▸ hordF)
  have : m.eid < q.eid := hpair.2.2 m hmtake q hq
  omega

/-- If the backend reports no more history before the cursor, the page is
empty — so the `LoadMore` affordance is correctly hidden. -/
theorem pageBefore_eq_nil_of_not_hasMore {hist : Buf} {c n : Nat}
    (h : hasMoreBefore hist c = false) : pageBefore hist c n = [] := by
  have : olderThan c hist = [] := by
    rw [olderThan, List.filter_eq_nil_iff]
    simpa [hasMoreBefore] using h
  simp [pageBefore, lastN, this]

/-- Conversely, if there is older history the page really is non-empty
(provided a positive page size), so paging always makes progress. -/
theorem pageBefore_ne_nil {hist : Buf} {c n : Nat} (hn : 0 < n)
    (h : hasMoreBefore hist c = true) : pageBefore hist c n ≠ [] := by
  have hne : olderThan c hist ≠ [] := by
    intro hnil
    rw [olderThan, List.filter_eq_nil_iff] at hnil
    simp only [hasMoreBefore, List.any_eq_true] at h
    obtain ⟨m, hm, hme⟩ := h
    exact absurd hme (by simpa [olderThan] using hnil m hm)
  have hlen : 0 < (olderThan c hist).length := List.length_pos_iff.mpr hne
  simp only [pageBefore, lastN, ne_eq, List.drop_eq_nil_iff, not_le]
  omega

private theorem countP_split (l : List Msg) (p q : Msg → Bool)
    (himp : ∀ x ∈ l, q x = true → p x = true) :
    l.countP p = l.countP q + l.countP (fun x => p x && !q x) := by
  induction l with
  | nil => simp
  | cons a t ih =>
      have ih' := ih (fun x hx => himp x (List.mem_cons_of_mem _ hx))
      have ha := himp a (List.mem_cons_self ..)
      simp only [List.countP_cons, ih']
      by_cases hq : q a = true
      · have hp : p a = true := ha hq
        simp only [hq, hp, if_pos, Bool.not_true, Bool.and_false]
        simp; omega
      · by_cases hp : p a = true
        · simp [hq, hp]
          omega
        · simp [hq, hp]

/-- **Pagination terminates.**  Moving the cursor from `c` to the earliest eid
of the fetched page strictly decreases the number of remaining older messages,
so repeated paging reaches `hasMore = false` in finitely many steps. -/
theorem paginationMeasureDecreases {hist : Buf} {c n : Nat} {q : Msg}
    (hq : q ∈ pageBefore hist c n) :
    (olderThan q.eid hist).length < (olderThan c hist).length := by
  have hqh : q ∈ hist := (mem_pageBefore_imp hq).1
  have hqc : q.eid < c := (mem_pageBefore_imp hq).2
  have hsplit := countP_split hist (fun m => decide (m.eid < c))
      (fun m => decide (m.eid < q.eid)) (by intro x _ hx; simp at hx ⊢; omega)
  have hpos : 0 < hist.countP (fun m => decide (m.eid < c) && !decide (m.eid < q.eid)) := by
    rw [List.countP_pos_iff]
    exact ⟨q, hqh, by simp [hqc]⟩
  simp only [olderThan, ← List.countP_eq_length_filter]
  rw [hsplit]
  exact Nat.lt_add_of_pos_right hpos

end ChatInfinite
