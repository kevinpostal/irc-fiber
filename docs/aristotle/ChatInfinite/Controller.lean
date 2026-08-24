import ChatInfinite.Scroll

/-!
# The controller: realtime appends, frozen render end, history loads

This file composes the data model (`ChatInfinite.Basic`) with the geometry
model (`ChatInfinite.Scroll`) into the controller that `ChatArea.svelte`
drives, and proves the end-to-end requirements:

* while the user is scrolled up, realtime traffic is *buffered* — it costs no
  layout work and does not move the render end (`frozen renderEndKey`);
* nothing is ever dropped: every realtime message is either rendered or
  pending, and returning to the bottom flushes all pending messages;
* history loading and realtime traffic are independent: they commute, so a
  slow backfill never blocks (or reorders) live messages;
* a history load moves the cursor strictly and preserves every structural
  invariant of the model.
-/

namespace ChatInfinite

/-- The controller state: geometry, rendered buffer (oldest first), realtime
messages held back while the user is scrolled up, sentinel guards, and the
pagination cursor (`beforeid`). -/
structure Model where
  scroll : ScrollState
  buf : Buf
  pending : Buf
  flags : LoadFlags
  cursor : Nat
  deriving DecidableEq, Repr

/-- The render end key: the index one past the newest rendered row.  It is
what Svelte keys the bottom of the list on. -/
def renderEndKey (m : Model) : Nat := m.buf.length

/-- A realtime message arrives.  At the bottom it is appended and rendered;
scrolled up it is queued, leaving geometry and render end untouched. -/
def receiveRealtime (m : Model) (msg : Msg) (rowPx : Nat) : Model :=
  if m.scroll.atBottom then
    { m with buf := m.buf ++ [msg], scroll := appendOne m.scroll rowPx }
  else
    { m with pending := m.pending ++ [msg] }

/-- Returning to the bottom flushes the queue in arrival order. -/
def flushPending (m : Model) (px : Nat) : Model :=
  { m with buf := m.buf ++ m.pending, pending := [],
           scroll := { m.scroll with scrollHeight := m.scroll.scrollHeight + px,
                                     totalMessages := m.scroll.totalMessages + m.pending.length } }

/-- A history page arrives: it is deduplicated into the buffer, the cursor
moves to the earliest returned event id, and the geometry is compensated in the
same synchronous flush. -/
def loadOlder (m : Model) (page : Buf) (d : Nat) : Model :=
  { m with buf := prependDedup m.buf page,
           scroll := prependCompensate m.scroll page.length d,
           cursor := (page.map Msg.eid).foldr min m.cursor }

/-! ## Realtime traffic is never dropped and never causes work while scrolled up -/

/-- **No dropped messages.**  A realtime message is always retained, either in
the rendered buffer or in the pending queue. -/
theorem noDroppedRealtime (m : Model) (msg : Msg) (rowPx : Nat) :
    msg ∈ (receiveRealtime m msg rowPx).buf ∨ msg ∈ (receiveRealtime m msg rowPx).pending := by
  by_cases h : m.scroll.atBottom <;> simp [receiveRealtime, h]

/-- Nothing already rendered or queued is lost by a realtime append. -/
theorem receiveRealtime_preserves (m : Model) (msg : Msg) (rowPx : Nat) (x : Msg) :
    x ∈ m.buf ∨ x ∈ m.pending →
    x ∈ (receiveRealtime m msg rowPx).buf ∨ x ∈ (receiveRealtime m msg rowPx).pending := by
  intro hx
  by_cases h : m.scroll.atBottom <;> rcases hx with hx | hx <;> simp [receiveRealtime, h, hx]

/-- **Frozen render end.**  While the user is scrolled up, realtime traffic
changes neither the geometry (no layout work, no reflow) nor the render end
key, so no row is recreated and the view cannot be yanked. -/
theorem frozenRenderEndWhileScrolledUp (m : Model) (msg : Msg) (rowPx : Nat)
    (h : m.scroll.atBottom = false) :
    (receiveRealtime m msg rowPx).scroll = m.scroll ∧
    renderEndKey (receiveRealtime m msg rowPx) = renderEndKey m ∧
    (receiveRealtime m msg rowPx).buf = m.buf := by
  simp [receiveRealtime, renderEndKey, h]

/-- At the bottom the message is rendered immediately, growing the render end
by exactly one. -/
theorem renderEndAdvancesAtBottom (m : Model) (msg : Msg) (rowPx : Nat)
    (h : m.scroll.atBottom = true) :
    renderEndKey (receiveRealtime m msg rowPx) = renderEndKey m + 1 := by
  simp [receiveRealtime, renderEndKey, h]

/-- **Flush on return to the bottom.**  Everything that was rendered or queued
is rendered afterwards, and the queue is empty: the buffered realtime burst is
delivered exactly once, in order. -/
theorem flushPendingDelivers (m : Model) (px : Nat) :
    (flushPending m px).pending = [] ∧
    (∀ x, x ∈ m.buf ∨ x ∈ m.pending → x ∈ (flushPending m px).buf) ∧
    (flushPending m px).buf = m.buf ++ m.pending := by
  refine ⟨rfl, ?_, rfl⟩
  intro x hx
  simpa [flushPending] using hx

/-! ## History loads do not interfere with realtime traffic -/

/-- **Independence.**  A history page arriving while a realtime message is
delivered yields the same buffer whichever order the two are applied in
(assuming, as the cursor guarantees, that the page is strictly older than the
live message).  So progressive backfill never blocks, reorders or duplicates
realtime output. -/
theorem realtimeCommutesWithHistoryLoad (m : Model) (page : Buf) (d : Nat) (msg : Msg)
    (rowPx : Nat) (hsep : ∀ p ∈ page, p.eid ≠ msg.eid) (hb : m.scroll.atBottom = true) :
    (receiveRealtime (loadOlder m page d) msg rowPx).buf =
      (loadOlder (receiveRealtime m msg rowPx) page d).buf := by
  have hdedup : dedupAgainst (m.buf ++ [msg]) page = dedupAgainst m.buf page := by
    unfold dedupAgainst
    refine List.filter_congr ?_
    intro p hp
    simp only [List.any_append, List.any_cons, List.any_nil, Bool.or_false,
      Bool.not_eq_eq_eq_not]
    have : (msg.eid == p.eid) = false := by
      simp only [beq_eq_false_iff_ne, ne_eq]
      exact fun hcon => hsep p hp hcon.symm
    simp [this]
  have hb' : (prependCompensate m.scroll page.length d).atBottom = true := hb
  simp only [receiveRealtime, loadOlder, hb, hb', if_pos, prependDedup, hdedup]
  simp [List.append_assoc]

/-- While scrolled up, a realtime message and a history load touch disjoint
parts of the model: the load only grows the buffer, the message only grows the
queue. -/
theorem historyLoadKeepsQueue (m : Model) (page : Buf) (d : Nat) (msg : Msg) (rowPx : Nat)
    (h : m.scroll.atBottom = false) :
    (loadOlder (receiveRealtime m msg rowPx) page d).pending = m.pending ++ [msg] ∧
    (loadOlder (receiveRealtime m msg rowPx) page d).buf = prependDedup m.buf page := by
  simp [receiveRealtime, loadOlder, h]

/-! ## Structural invariant of a history load -/

/-- The invariant the controller maintains between frames. -/
structure Invariant (m : Model) : Prop where
  wf : WF m.scroll
  ordered : Ordered m.buf
  /-- the cursor is the eid of the oldest buffered message (or the initial
  sentinel value when the buffer is empty) -/
  cursorLB : ∀ x ∈ m.buf, m.cursor ≤ x.eid

theorem foldr_min_le {l : List Nat} {c : Nat} : l.foldr min c ≤ c := by
  induction l with
  | nil => exact le_rfl
  | cons a t ih => exact le_trans (min_le_right a _) ih

theorem foldr_min_le_of_mem {l : List Nat} {c x : Nat} (hx : x ∈ l) : l.foldr min c ≤ x := by
  induction l with
  | nil => exact absurd hx (List.not_mem_nil)
  | cons a t ih =>
      rcases List.mem_cons.mp hx with rfl | hx
      · exact min_le_left _ _
      · exact le_trans (min_le_right a _) (ih hx)

/-- **A history load preserves every invariant and advances the cursor.**  The
buffer stays ordered and duplicate-free, the geometry stays well formed with an
unchanged anchor, and the cursor becomes the earliest eid of the merged buffer
— strictly smaller whenever the page was non-empty, so the next request cannot
repeat the previous one (no phantom cursor stall). -/
theorem loadOlder_invariant (m : Model) (page : Buf) (d : Nat) (hI : Invariant m)
    (hpage : Ordered page) (hsep : ∀ p ∈ page, p.eid < m.cursor) :
    Invariant (loadOlder m page d) ∧
    anchorFromBottom (loadOlder m page d).scroll = anchorFromBottom m.scroll ∧
    (∀ q ∈ page, (loadOlder m page d).cursor ≤ q.eid) ∧
    (loadOlder m page d).cursor ≤ m.cursor := by
  have hstrict : ∀ p ∈ page, ∀ o ∈ m.buf, p.eid < o.eid := by
    intro p hp o ho
    exact lt_of_lt_of_le (hsep p hp) (hI.cursorLB o ho)
  refine ⟨⟨hI.wf.prependCompensate _ _, Ordered.prependDedup hI.ordered hpage hstrict, ?_⟩, ?_, ?_, ?_⟩
  · intro x hx
    simp only [loadOlder] at hx ⊢
    rcases List.mem_append.mp hx with hx | hx
    · exact foldr_min_le_of_mem (List.mem_map_of_mem (mem_dedupAgainst.mp hx).1)
    · exact le_trans foldr_min_le (hI.cursorLB x hx)
  · simp only [loadOlder, anchorFromBottom, prependCompensate]
    omega
  · intro q hq
    exact foldr_min_le_of_mem (List.mem_map_of_mem hq)
  · exact foldr_min_le

/-- With a non-empty page the cursor moves **strictly**, so paging always makes
progress and can never re-request the same window. -/
theorem loadOlder_cursor_strict (m : Model) (page : Buf) (d : Nat) {q : Msg} (hq : q ∈ page)
    (hsep : ∀ p ∈ page, p.eid < m.cursor) :
    (loadOlder m page d).cursor < m.cursor := by
  simp only [loadOlder]
  exact lt_of_le_of_lt (foldr_min_le_of_mem (List.mem_map_of_mem hq)) (hsep q hq)

/-- Delivering the same page twice (a retried request, or a sentinel that fires
twice before `loading` latches) is a no-op on the buffer. -/
theorem loadOlder_buf_idempotent (m : Model) (page : Buf) (d d' : Nat) :
    (loadOlder (loadOlder m page d) page d').buf = (loadOlder m page d).buf :=
  prependDedup_idempotent m.buf page

end ChatInfinite
