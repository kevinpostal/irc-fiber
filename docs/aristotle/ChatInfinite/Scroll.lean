import ChatInfinite.Basic

/-!
# Scroll geometry: compensation, sentinel, stick band, windowing, auto-fill

This file models the *geometry* half of IRC Fiber's reverse infinite scroll.

The observable state of the scroll container is `ScrollState`.  All quantities
are pixels/counts, so `Nat` with the browser invariant
`scrollTop + clientHeight ≤ scrollHeight` (`WF`).

The main results are

* `scrollTopPreservedAfterPrepend` — the compensated prepend keeps the visual
  viewport fixed (the content anchored at the viewport top does not move);
* `noFlickerSameFrame` — the *frame sequence* produced by the compensated
  prepend never exposes an intermediate state with the wrong `scrollTop`,
  whereas the uncompensated version provably does (`naivePrependFlickers`);
* `sentinelPreloadFiresBeforeTop` — the 200px `rootMargin` sentinel fires
  strictly before the top is reached, and never wedges at `scrollTop = 0`;
* `atBottomStickiness` — the 70px stick band re-engages on downward scroll but
  a small upward scroll inside the band never yanks the viewport back;
* `boundedWindow` — the trim rule keeps the rendered window bounded by
  `TRIM_DETECT_THRESHOLD`, is idempotent and never enlarges the window;
* `progressiveLoadTerminates` / `eventuallyScrollableOrExhausted` — the silent
  viewport-fill loop halts after at most `MAX_SILENT_FILLS` batches, in a state
  that is scrollable, exhausted, or fill-capped.
-/

namespace ChatInfinite

/-! ## Tunables (mirroring the TypeScript constants) -/

/-- `BATCH_SIZE`: rendered window size the trimmer targets. -/
def BATCH_SIZE : Nat := 200
/-- `TRIM_DETECT_THRESHOLD`: window size above which the trimmer fires. -/
def TRIM_DETECT_THRESHOLD : Nat := 350
/-- `STICK_BAND_PX`: distance from the bottom within which stickiness
re-engages on a downward scroll. -/
def STICK_BAND_PX : Nat := 70
/-- `rootMargin` of the top sentinel `IntersectionObserver`. -/
def SENTINEL_MARGIN_PX : Nat := 200
/-- `MAX_SILENT_FILLS`: cap on silent viewport-fill iterations. -/
def MAX_SILENT_FILLS : Nat := 3

theorem batch_lt_trim : BATCH_SIZE < TRIM_DETECT_THRESHOLD := by decide

/-! ## Scroll state -/

structure ScrollState where
  scrollTop : Nat
  scrollHeight : Nat
  clientHeight : Nat
  renderStart : Nat
  totalMessages : Nat
  atBottom : Bool
  deriving DecidableEq, Repr

/-- Browser well-formedness: the viewport lies inside the content, and the
render window starts inside the buffer. -/
structure WF (s : ScrollState) : Prop where
  viewport : s.scrollTop + s.clientHeight ≤ s.scrollHeight
  window : s.renderStart ≤ s.totalMessages

/-- Pixels between the bottom of the viewport and the bottom of the content. -/
def distanceFromBottom (s : ScrollState) : Nat :=
  s.scrollHeight - (s.scrollTop + s.clientHeight)

/-- The *scroll anchor*: how far the top of the viewport is from the bottom of
the content.  Everything the user is looking at is determined by this number
(plus `clientHeight`), so "no visual jump" is exactly "anchor unchanged". -/
def anchorFromBottom (s : ScrollState) : Nat := s.scrollHeight - s.scrollTop

/-- The container can actually be scrolled. -/
def isScrollable (s : ScrollState) : Bool := decide (s.clientHeight < s.scrollHeight)

/-- Number of rendered rows. -/
def windowSize (s : ScrollState) : Nat := s.totalMessages - s.renderStart

/-! ## Scroll-anchored prepend -/

/-- Store-level prepend (`prependMessages`): `k` older messages enter the
buffer.  Absolute indices shift by `k`, so the window start shifts with them
and *nothing* about the rendered output or the geometry changes. -/
def prependStore (s : ScrollState) (k : Nat) : ScrollState :=
  { s with totalMessages := s.totalMessages + k, renderStart := s.renderStart + k }

/-- Reveal `k` already-buffered older rows, worth `d` pixels, above the
viewport, compensating `scrollTop` by the same `d` (`revealBacklogFromMemory`,
inside one `flushSync`). -/
def revealOlder (s : ScrollState) (k d : Nat) : ScrollState :=
  { s with renderStart := s.renderStart - k,
           scrollTop := s.scrollTop + d,
           scrollHeight := s.scrollHeight + d }

/-- Fetch-and-reveal in a single synchronous flush: the store shift and the
reveal cancel on `renderStart`, so the rendered window simply grows by the `k`
new rows while the scroll anchor is compensated by their height `d`. -/
def prependCompensate (s : ScrollState) (k d : Nat) : ScrollState :=
  { s with scrollTop := s.scrollTop + d,
           scrollHeight := s.scrollHeight + d,
           totalMessages := s.totalMessages + k }

theorem prependCompensate_eq (s : ScrollState) (k d : Nat) :
    prependCompensate s k d = revealOlder (prependStore s k) k d := by
  simp [prependCompensate, revealOlder, prependStore]

/-- A store prepend on its own is geometry-free: while the user is scrolled up,
history arriving in the store costs no layout work. -/
theorem prependStore_no_layout (s : ScrollState) (k : Nat) :
    (prependStore s k).scrollTop = s.scrollTop ∧
    (prependStore s k).scrollHeight = s.scrollHeight ∧
    windowSize (prependStore s k) = windowSize s := by
  refine ⟨rfl, rfl, ?_⟩
  simp only [windowSize, prependStore]
  omega

/-- **Scroll preservation.**  Prepending `k` messages that add `d` pixels of
content above the viewport, together with `scrollTop' = scrollTop + d`, leaves
the visual viewport exactly where it was: same anchor, same distance from the
bottom, same rendered rows. -/
theorem scrollTopPreservedAfterPrepend (s : ScrollState) (k d : Nat) (h : WF s) :
    (prependCompensate s k d).scrollTop = s.scrollTop + d ∧
    (prependCompensate s k d).scrollHeight = s.scrollHeight + d ∧
    anchorFromBottom (prependCompensate s k d) = anchorFromBottom s ∧
    distanceFromBottom (prependCompensate s k d) = distanceFromBottom s ∧
    windowSize (prependCompensate s k d) = windowSize s + k := by
  obtain ⟨hv, hw⟩ := h
  refine ⟨rfl, rfl, ?_, ?_, ?_⟩ <;>
    simp only [prependCompensate, anchorFromBottom, distanceFromBottom, windowSize] <;> omega

/-- The compensated prepend keeps the state well formed. -/
theorem WF.prependCompensate {s : ScrollState} (h : WF s) (k d : Nat) :
    WF (prependCompensate s k d) := by
  obtain ⟨hv, hw⟩ := h
  exact ⟨by simp only [ChatInfinite.prependCompensate]; omega,
         by simp only [ChatInfinite.prependCompensate]; omega⟩


/-- Prepending is *silent* for the bottom of the buffer: the newest message
stays at the same distance from the bottom, so realtime appends interleave
freely with history loads. -/
theorem prepend_preserves_bottom (s : ScrollState) (k d : Nat) :
    (prependCompensate s k d).scrollHeight - (prependCompensate s k d).scrollTop
      = s.scrollHeight - s.scrollTop := by
  simp only [prependCompensate]; omega

/-! ## Frame-level atomicity (no flicker) -/

/-- The frames a compositor could observe for the compensated prepend: the DOM
mutation and the `scrollTop` write happen inside one synchronous flush, so the
only observable states are "before" and "after". -/
def framesAtomic (s : ScrollState) (k d : Nat) : List ScrollState :=
  [s, prependCompensate s k d]

/-- The frames of the naive implementation, where the DOM grows in one frame
and `scrollTop` is fixed up in a later one (`requestAnimationFrame`
compensation).  The middle frame is the flicker. -/
def framesNaive (s : ScrollState) (k d : Nat) : List ScrollState :=
  [s,
   { s with scrollHeight := s.scrollHeight + d,
            renderStart := s.renderStart + k,
            totalMessages := s.totalMessages + k },
   prependCompensate s k d]

/-- **No flicker.**  Every observable frame of the atomic prepend has the same
scroll anchor: there is no intermediate frame with a wrong `scrollTop`. -/
theorem noFlickerSameFrame (s : ScrollState) (k d : Nat) :
    ∀ f ∈ framesAtomic s k d, anchorFromBottom f = anchorFromBottom s := by
  intro f hf
  rcases List.mem_cons.mp hf with rfl | hf
  · rfl
  · rcases List.mem_cons.mp hf with rfl | hf
    · simp only [anchorFromBottom, prependCompensate]; omega
    · exact absurd hf (List.not_mem_nil)

/-- The model has teeth: deferring the compensation to a later frame really
does expose a frame whose anchor jumped by the height of the inserted
content. -/
theorem naivePrependFlickers (s : ScrollState) (k d : Nat) (h : WF s) (hd : 0 < d) :
    ∃ f ∈ framesNaive s k d, anchorFromBottom f ≠ anchorFromBottom s := by
  refine ⟨_, List.mem_cons_of_mem _ (List.mem_cons_self ..), ?_⟩
  have hv := h.viewport
  show s.scrollHeight + d - s.scrollTop ≠ s.scrollHeight - s.scrollTop
  omega

/-! ## Sentinel -/

/-- The 1px top sentinel with `rootMargin: '200px 0px 0px 0px'` intersects the
scroll root exactly when the viewport top is within 200px of the content top. -/
def sentinelIntersects (s : ScrollState) : Bool := decide (s.scrollTop ≤ SENTINEL_MARGIN_PX)

/-- **Preload fires before the top is reached.**  The sentinel is visible for
every `scrollTop ≤ 200`, in particular strictly before `scrollTop = 0`, and it
is *not* visible below the band — so there is no dead zone and no spurious
firing deep in the buffer. -/
theorem sentinelPreloadFiresBeforeTop (s : ScrollState) :
    sentinelIntersects s = true ↔ s.scrollTop ≤ 200 := by
  simp [sentinelIntersects, SENTINEL_MARGIN_PX]

/-- Flags guarding the sentinel callback `onSentinelVisible`. -/
structure LoadFlags where
  loading : Bool
  noMoreHistory : Bool
  cleared : Bool
  deriving DecidableEq, Repr

/-- The load decision taken when the sentinel becomes visible. -/
def shouldLoad (s : ScrollState) (f : LoadFlags) : Bool :=
  sentinelIntersects s && !f.loading && !f.noMoreHistory && !f.cleared && isScrollable s

/-- **No wedge at the top.**  If the user is stranded at `scrollTop = 0` with a
scrollable container and history still available, a load is issued (the sentinel
is never stuck "already intersecting, never re-fires"). -/
theorem noWedgeAtTop (s : ScrollState) (f : LoadFlags) (h0 : s.scrollTop = 0)
    (hs : isScrollable s = true) (hl : f.loading = false) (hn : f.noMoreHistory = false)
    (hc : f.cleared = false) : shouldLoad s f = true := by
  simp [shouldLoad, sentinelIntersects, SENTINEL_MARGIN_PX, h0, hs, hl, hn, hc]

/-- The guards really do suppress duplicate work: an in-flight load, an
exhausted history, a cleared buffer or a non-scrollable container all block. -/
theorem shouldLoad_false_of_guard (s : ScrollState) (f : LoadFlags)
    (h : f.loading = true ∨ f.noMoreHistory = true ∨ f.cleared = true ∨
         isScrollable s = false) : shouldLoad s f = false := by
  rcases h with h | h | h | h <;> simp [shouldLoad, h]

/-! ## Stick band -/

/-- rAF-coalesced scroll handler.  A movement upwards always disengages
stickiness; a movement downwards re-engages it once inside the 70px band. -/
def onScrollTick (s : ScrollState) (newTop : Nat) : ScrollState :=
  let scrolledUp := newTop < s.scrollTop
  let s' := { s with scrollTop := newTop }
  { s' with atBottom := if scrolledUp then false else decide (distanceFromBottom s' ≤ STICK_BAND_PX) }

/-- The post-layout pass: only a *sticky* view is snapped to the bottom. -/
def applyStick (s : ScrollState) : ScrollState :=
  if s.atBottom then { s with scrollTop := s.scrollHeight - s.clientHeight } else s

/-- **Stick-band semantics.**

1. scrolling *down* to within 70px of the bottom re-engages stickiness, and the
   next layout pass snaps to the bottom;
2. scrolling *up* — even by 50px, i.e. while still inside the band — disengages
   stickiness and the layout pass leaves `scrollTop` exactly where the user put
   it: the view is never yanked. -/
theorem atBottomStickiness (s : ScrollState) (newTop : Nat) :
    (s.scrollTop ≤ newTop → distanceFromBottom { s with scrollTop := newTop } ≤ STICK_BAND_PX →
      (onScrollTick s newTop).atBottom = true ∧
      (applyStick (onScrollTick s newTop)).scrollTop = s.scrollHeight - s.clientHeight) ∧
    (newTop < s.scrollTop →
      (onScrollTick s newTop).atBottom = false ∧
      (applyStick (onScrollTick s newTop)).scrollTop = newTop) := by
  constructor
  · intro hdown hband
    have hnot : ¬ newTop < s.scrollTop := by omega
    simp [onScrollTick, applyStick, hnot, hband]
  · intro hup
    simp [onScrollTick, applyStick, hup]

/-- Being outside the band keeps the view unsticky whichever way the user
moved, so an unread backlog is never scrolled away. -/
theorem notSticky_outside_band (s : ScrollState) (newTop : Nat)
    (h : STICK_BAND_PX < distanceFromBottom { s with scrollTop := newTop }) :
    (onScrollTick s newTop).atBottom = false := by
  by_cases hup : newTop < s.scrollTop
  · simp [onScrollTick, hup]
  · simp only [onScrollTick, hup, if_false, decide_eq_false_iff_not, not_le]
    simpa [distanceFromBottom] using h

/-! ## Bounded window (trim) -/

/-- The trimmer: once the rendered window exceeds `TRIM_DETECT_THRESHOLD`,
drop the oldest rows so that exactly `BATCH_SIZE` remain.  The dropped rows
were above the viewport, so `scrollTop` is compensated by their height
`removedPx` — the same anchoring rule as the prepend, in the other direction. -/
def applyTrim (s : ScrollState) (removedPx : Nat) : ScrollState :=
  if TRIM_DETECT_THRESHOLD < windowSize s then
    { s with renderStart := s.totalMessages - BATCH_SIZE,
             scrollTop := s.scrollTop - removedPx,
             scrollHeight := s.scrollHeight - removedPx }
  else s

/-- **Bounded window.**  After the trim pass the rendered window is at most
`TRIM_DETECT_THRESHOLD` rows; it is either exactly `BATCH_SIZE` (a trim
happened) or unchanged and already within budget; and the window start only
ever moves forwards, staying inside the buffer. -/
theorem boundedWindow (s : ScrollState) (removedPx : Nat) (h : WF s) :
    windowSize (applyTrim s removedPx) ≤ TRIM_DETECT_THRESHOLD ∧
    (windowSize (applyTrim s removedPx) = BATCH_SIZE ∨
      windowSize (applyTrim s removedPx) = windowSize s) ∧
    s.renderStart ≤ (applyTrim s removedPx).renderStart ∧
    (applyTrim s removedPx).renderStart ≤ (applyTrim s removedPx).totalMessages := by
  have hw := h.window
  unfold applyTrim windowSize
  by_cases hbig : TRIM_DETECT_THRESHOLD < s.totalMessages - s.renderStart
  · rw [if_pos hbig]
    simp only [TRIM_DETECT_THRESHOLD, BATCH_SIZE] at *
    exact ⟨by omega, Or.inl (by omega), by omega, by omega⟩
  · rw [if_neg hbig]
    exact ⟨by omega, Or.inr rfl, le_rfl, hw⟩

/-- The trim is idempotent: a second pass in the same frame does nothing, so
trimming costs O(1) amortised work and cannot loop. -/
theorem applyTrim_idempotent (s : ScrollState) (removedPx : Nat) (h : WF s) :
    applyTrim (applyTrim s removedPx) 0 = applyTrim s removedPx := by
  have hnot : ¬ TRIM_DETECT_THRESHOLD < windowSize (applyTrim s removedPx) := by
    have hb := (boundedWindow s removedPx h).1
    omega
  conv_lhs => rw [applyTrim, if_neg hnot]

/-- Appending one realtime row and then trimming preserves the DOM budget:
the window is bounded by `TRIM_DETECT_THRESHOLD` for ever. -/
def appendOne (s : ScrollState) (rowPx : Nat) : ScrollState :=
  { s with scrollHeight := s.scrollHeight + rowPx, totalMessages := s.totalMessages + 1 }

theorem windowBoundInvariant (s : ScrollState) (rowPx removedPx : Nat) (h : WF s) :
    windowSize (applyTrim (appendOne s rowPx) removedPx) ≤ TRIM_DETECT_THRESHOLD ∧
    (applyTrim (appendOne s rowPx) removedPx).totalMessages = s.totalMessages + 1 := by
  have h' : WF (appendOne s rowPx) :=
    ⟨by simp only [appendOne]; have := h.viewport; omega,
     by simp only [appendOne]; have := h.window; omega⟩
  refine ⟨(boundedWindow (appendOne s rowPx) removedPx h').1, ?_⟩
  unfold applyTrim
  split <;> rfl

/-! ## Silent viewport-fill loop -/

/-- Remaining history, as a list of pages `(rowCount, heightPx)` handed out
oldest-request-first.  `[]` means the history is exhausted. -/
abbrev Pages := List (Nat × Nat)

/-- `tryAutoFillSilent`: while the container is not scrollable, keep prepending
(silently — no "Fetching…" divider) until it is scrollable, the history is
exhausted, or the fill budget is spent.  Each prepend is scroll-compensated,
hence flicker free. -/
def autoFill : Nat → ScrollState → Pages → ScrollState × Nat × Pages
  | 0, s, pages => (s, 0, pages)
  | fuel + 1, s, pages =>
    if isScrollable s then (s, 0, pages)
    else
      match pages with
      | [] => (s, 0, [])
      | (k, d) :: rest =>
        let r := autoFill fuel (prependCompensate s k d) rest
        (r.1, r.2.1 + 1, r.2.2)

/-- The loop never performs more than its fuel worth of silent fetches. -/
theorem autoFill_fills_le (fuel : Nat) (s : ScrollState) (pages : Pages) :
    (autoFill fuel s pages).2.1 ≤ fuel := by
  induction fuel generalizing s pages with
  | zero => simp [autoFill]
  | succ n ih =>
      simp only [autoFill]
      split
      · simp
      · split
        · simp
        · exact Nat.succ_le_succ (ih _ _)

/-- **Progressive load terminates.**  Running the fill loop with
`MAX_SILENT_FILLS` of fuel always halts, having spent at most
`MAX_SILENT_FILLS` silent fetches. -/
theorem progressiveLoadTerminates (s : ScrollState) (pages : Pages) :
    (autoFill MAX_SILENT_FILLS s pages).2.1 ≤ MAX_SILENT_FILLS :=
  autoFill_fills_le _ _ _

/-- **Liveness.**  The loop stops only in a good state: either the container
became scrollable, or the history is exhausted, or the whole fill budget was
spent (in which case the sentinel takes over on the next user scroll). -/
theorem eventuallyScrollableOrExhausted (fuel : Nat) (s : ScrollState) (pages : Pages) :
    isScrollable (autoFill fuel s pages).1 = true ∨
    (autoFill fuel s pages).2.2 = [] ∨
    (autoFill fuel s pages).2.1 = fuel := by
  induction fuel generalizing s pages with
  | zero => exact Or.inr (Or.inr rfl)
  | succ n ih =>
      simp only [autoFill]
      split
      · rename_i hs; exact Or.inl hs
      · split
        · exact Or.inr (Or.inl rfl)
        · rename_i k d rest
          rcases ih (prependCompensate s k d) rest with h | h | h
          · exact Or.inl h
          · exact Or.inr (Or.inl h)
          · exact Or.inr (Or.inr (by simp [h]))

/-- Each iteration of the fill loop is anchor preserving, so the silent fill is
invisible to the user: no jump and no "Fetching…" flash. -/
theorem autoFill_preserves_anchor (fuel : Nat) (s : ScrollState) (pages : Pages) (h : WF s) :
    anchorFromBottom (autoFill fuel s pages).1 = anchorFromBottom s ∧
    WF (autoFill fuel s pages).1 := by
  induction fuel generalizing s pages with
  | zero => exact ⟨rfl, h⟩
  | succ n ih =>
      simp only [autoFill]
      split
      · exact ⟨rfl, h⟩
      · split
        · exact ⟨rfl, h⟩
        · rename_i k d rest
          obtain ⟨ha, hwf⟩ := ih (prependCompensate s k d) rest (h.prependCompensate k d)
          refine ⟨?_, hwf⟩
          rw [ha]
          simp only [anchorFromBottom, prependCompensate]
          omega

/-- The fill loop only consumes history from the front, never re-requests a
page, and never drops one: the remaining pages are a suffix of the input. -/
theorem autoFill_pages_suffix (fuel : Nat) (s : ScrollState) (pages : Pages) :
    (autoFill fuel s pages).2.2 <:+ pages := by
  induction fuel generalizing s pages with
  | zero => exact List.suffix_refl _
  | succ n ih =>
      cases pages with
      | nil => simp only [autoFill]; split <;> simp
      | cons p rest =>
        obtain ⟨k, d⟩ := p
        simp only [autoFill]
        split
        · exact List.suffix_refl _
        · exact (ih (prependCompensate s k d) rest).trans (List.suffix_cons _ _)

end ChatInfinite
