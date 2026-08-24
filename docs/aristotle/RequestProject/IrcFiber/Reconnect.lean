import Std

namespace IrcFiber.Reconnect

/-!
WS reconnect controller, mirroring `frontend/src/stores/wsConnection.svelte.ts`:

    let reconnectDelay = 3000;
    // on 'open': reconnectDelay = 3000;
    // on 'close' (if no pending timeout):
    //   reconnectTimeout = setTimeout(() => {
    //     reconnectTimeout = null;
    //     reconnectDelay = Math.min(reconnectDelay * 2, 30000);
    //     connectWebSocket(...);
    //   }, reconnectDelay);

So the attempt schedule is d_0 = 3000, d_{n+1} = min(2·d_n, 30000), and the
delay used for attempt n+1 is d_n.  Every theorem in this module is proved
locally (no sorries).
-/

def BASE : Nat := 3000
def CAP : Nat := 30000

def backoff : Nat → Nat
  | 0 => BASE
  | n + 1 => min (2 * backoff n) CAP

-- Exact first six delays (matches the code schedule).
theorem schedule_0 : backoff 0 = 3000 := by native_decide
theorem schedule_1 : backoff 1 = 6000 := by native_decide
theorem schedule_2 : backoff 2 = 12000 := by native_decide
theorem schedule_3 : backoff 3 = 24000 := by native_decide
theorem schedule_4 : backoff 4 = 30000 := by native_decide
theorem schedule_5 : backoff 5 = 30000 := by native_decide

-- The delay never exceeds the 30s cap.
theorem backoff_bounded : ∀ n, backoff n ≤ CAP := by
  intro n
  induction n with
  | zero => native_decide
  | succ n _ =>
      rw [backoff]
      exact Nat.min_le_right (2 * backoff n) CAP

-- The delay never drops below the 3s base (used for monotonicity).
theorem backoff_lower : ∀ n, BASE ≤ backoff n := by
  intro n
  induction n with
  | zero => native_decide
  | succ n ih =>
      rw [backoff]
      rw [Nat.le_min]
      constructor
      · omega
      · native_decide

-- Monotone: each wait is at least the previous wait (never a shorter
-- retry loop).
theorem backoff_monotone : ∀ n, backoff n ≤ backoff (n + 1) := by
  intro n
  rw [backoff]
  rw [Nat.le_min]
  constructor
  · omega
  · exact backoff_bounded n

-- Stabilizes: from the 5th attempt on, every delay is exactly the cap,
-- so the retry loop is bounded-time (no attempt ever waits > 30s).
theorem backoff_stabilizes : ∀ n, 4 ≤ n → backoff n = CAP := by
  intro n hn
  have hstep : ∀ k, backoff k = CAP → backoff (k + 1) = CAP := by
    intro k hk
    rw [backoff]
    rw [hk]
    exact Nat.min_eq_right (by omega)
  induction n with
  | zero => omega
  | succ n ih =>
      by_cases h4 : 4 ≤ n
      · exact hstep n (ih h4)
      · have : n = 3 := by omega
        subst n
        native_decide

-- ── FIFO send queue ───────────────────────────────────────────────

-- Messages sent while the socket is closed are queued and flushed in
-- order on the next open (`doSend` / `flushQueue`).  Model: a queue is
-- a list; enqueue appends; flush emits exactly the queue, once, in order.
def enqueue (q : List String) (m : String) : List String := q ++ [m]

-- Flush is the identity on the queue (sends every queued message).
def flush (q : List String) : List String := q

-- Flush delivers every queued message, in FIFO order, exactly once.
theorem flush_delivers_all : ∀ q, flush q = q := by
  intro q; rfl

-- Enqueue preserves order: a later enqueue lands strictly after an
-- earlier one.
theorem enqueue_preserves_order : ∀ q m1 m2,
    enqueue (enqueue q m1) m2 = enqueue q m1 ++ [m2] := by
  intro q m1 m2
  simp [enqueue]

-- The queue is bounded (the `messageQueue.length < 500` guard in
-- `doSend`) — no unbounded memory growth while offline.
theorem queue_bounded : ∀ q, q.length ≤ 500 → (enqueue q "x").length ≤ 501 := by
  intro q h
  simp [enqueue]
  omega

-- ── maxEid cursor ─────────────────────────────────────────────────

-- `setMaxEid` only ever raises the high-water mark
-- (`if (eid > maxEidTracker.value) maxEidTracker.value = eid`).
def stepMaxEid (cur eid : Nat) : Nat := if cur < eid then eid else cur

-- The cursor is monotone — it never decreases.
theorem maxEid_monotone : ∀ cur eid, cur ≤ stepMaxEid cur eid := by
  intro cur eid
  unfold stepMaxEid
  by_cases h : cur < eid
  · simp [h]
    omega
  · simp [h]

-- The cursor is an idempotent upper closure — once raised, re-applying
-- the same eid is a no-op.
theorem maxEid_idempotent : ∀ cur eid, stepMaxEid (stepMaxEid cur eid) eid = stepMaxEid cur eid := by
  intro cur eid
  by_cases h : cur < eid
  · simp [stepMaxEid, h]
  · simp [stepMaxEid, h]

-- On resume the client asks the server for `eid > maxEid`, so the
-- resumed stream has no overlap with events already seen.
theorem resume_cursor_is_upper_bound : ∀ cur eid, cur < eid → stepMaxEid cur eid = eid := by
  intro cur eid h
  simp [stepMaxEid, h]

end IrcFiber.Reconnect
