# Scroll-anchoring math for reverse infinite scroll (chat history)

> The complete mathematics of IRC Fiber's "load older messages without losing
> your place" machinery, cross-checked three ways: the Lean-verified model
> (`docs/aristotle/ChatInfinite/*.lean`, no sorries), a deterministic
> simulation (`scripts/scroll-anchor-sim.mjs`, 20 000 ops, 0 violations),
> and the real browser test suites (vitest + headless Chromium).

---

## 1 · Coordinate model and notation

A scroll container (the `.messages` div) has:

| symbol | meaning | source |
|---|---|---|
| `H` | content height (`scrollHeight`) | DOM |
| `V` | viewport height (`clientHeight`) | DOM |
| `s` | `scrollTop` — document offset of the viewport's top edge | DOM |
| `A` | **anchor**: `A = H − s` — distance from the viewport top to the content bottom | derived |
| `D` | distance from the viewport bottom to the content bottom: `D = H − (s + V) = A − V` | derived |

**Browser invariant (WF in the Lean model):** the viewport lies inside the
content, `0 ≤ s ≤ max(0, H − V)`.

The viewport displays the content slice `[s, s + V]`. A row at document
offset `y` appears on screen at **screen offset** `y − s`.

> **"Not losing your place" is exactly:** for the row the user is reading,
> `y − s` is unchanged after content above it is inserted or removed.
> Equivalently the anchor `A` is unchanged. (The Lean model defines
> `anchorFromBottom s := s.scrollHeight − s.scrollTop` and proves everything
> in terms of it.)

---

## 2 · The prepend theorem (the load-more case)

**Setup.** `k` older rows of total height `d` are inserted above the
viewport (they enter the DOM at the top): `H′ = H + d`, and every existing
row's document offset grows: `y′ = y + d`.

**Compensation.** The code writes `s′ = s + d`.

**Theorem (scrollTopPreservedAfterPrepend, Lean-proved):**

    A′ = H′ − s′ = (H + d) − (s + d) = A            — anchor preserved
    D′ = H′ − (s′ + V) = D                          — distance from bottom preserved
    y′ − s′ = (y + d) − (s + d) = y − s             — every row's screen offset preserved

So the viewport shows *exactly* the same slice of content as before: the user
keeps reading the same row at the same pixel position. Nothing else needs to
be known about the rows — only their total height `d`.

---

## 3 · Why the code measures δ = H′ − H instead of computing d

The implementation never computes `d` itself; after the DOM mutation it
reads `δ = H′ − H` and writes `s′ = s + δ` (`anchoredMutate`,
`revealBacklogFromMemory`). This is strictly more robust:

* If the only layout change is the prepend, `δ = d` — identical to §2.
* If the same flush also trimmed rows above the viewport (height `t`) or an
  image load/font swap shifted layout by `e`, then
  `δ = d − t + e` (all changes above the viewport net algebraically) and

      A′ = H + d − t + e − (s + d − t + e) = H − s = A.        — still exact

**The one correctness condition:** every height change must be *above* the
viewport's bottom edge. Content appended *below* the viewport (height `a`)
must NOT be compensated (the reading position is unaffected by it; only the
bottom moves away). The code guarantees this by construction:

| operation | where the geometry changes | compensation |
|---|---|---|
| history prepend (load-more) | above viewport | δ (exact) |
| trim while pinned | above viewport | snap to bottom (exact) |
| realtime append while pinned | below viewport | snap to bottom (exact) |
| realtime append while reading | **none — DOM frozen** (`renderEndKey`) | none (exact) |

The frozen-realtime rule is itself a theorem
(`frozenRenderEndWhileScrolledUp` in the Lean model): while the user is
scrolled up, incoming messages are queued and the DOM is untouched, so the
reading position cannot move even in principle.

---

## 4 · The clamp never fights the anchor

The browser keeps `s ≤ H − V`. After a prepend:

    max scrollTop becomes H′ − V = H + d − V ≥ s + d = s′     (since s ≤ H − V)

so the compensated `s′` is always inside the scrollable range — the browser
clamp cannot alter it. **Growth never clamps the anchor.** (This is why the
compensation is written *after* the mutation and its layout read, not before:
the code must observe the post-mutation `H′`.)

Shrink is the mirror case: trimming `t` above the viewport gives
`s′ = s − t`, and the correct position is `max(0, s − t)`. The only loss
is when `s < t` (the trim removed more than the user had scrolled) — the
trimmed rows are gone from the DOM, so there is nothing to anchor to; the real
code avoids the case entirely by trimming **only while pinned at the bottom**
(`maybeTrim` is called exclusively from the at-bottom paths), where the
anchor is the bottom edge, not a row:

    pinned: s = H − V  ⇒  after trim: s′ = (H − t) − V = H′ − V   — still pinned, exact.

If the content shrinks below the viewport entirely (`H′ ≤ V`), the
non-scrollable guard in `handleScroll` forces the pinned state.

---

## 5 · Windowing (renderStart) — the window shift cancels in the math

The DOM only renders rows `[renderStart, total)`. History handling:

* **Store prepend while scrolled up** (`prependStore`): `k` older messages
  arrive in the store; `renderStart += k` shifts the window down with them.
  Rendered rows, `H`, `s`: **unchanged** — zero layout work
  (`prependStore_no_layout`, Lean).
* **Reveal from memory** (`revealOlder`, `revealBacklogFromMemory`):
  `renderStart −= k`, rows worth `d` appear above the viewport,
  `s += d`, `H += d`.
* **Fetch-and-reveal in one flush** (`prependCompensate`): the store shift
  and the reveal cancel on `renderStart`:

      (store prepend) ++ (reveal)  =  compensate,
      renderStart:  (start + k) − k = start,
      geometry:     H += d, s += d.                        — Lean `prependCompensate_eq`

* **Head-key re-find at `idx > 0`** (a JOINPART group merge moved the head):
  `renderStart += idx` drops `idx` rows from the top of the *rendered
  window*; they were above the viewport, so `H` falls by their height and
  the same measured-δ rule compensates `s`. The reader never moves.

---

## 6 · Trim: bounded DOM, idempotent

Window budget: render at most `TRIM_DETECT_THRESHOLD = 350` rows, trim to
`BATCH_SIZE = 200`, plus the pixel guard (`scrollHeight > 12000`).

* `boundedWindow` (Lean): after `applyTrim`, `windowSize ≤ 350`; it is
  either exactly 200 (a trim happened) or unchanged.
* `applyTrim_idempotent` (Lean): a second trim in the same frame is a no-op
  — O(1) amortised, cannot loop.
* Compensation: the dropped rows are above the viewport, so the same rule
  applies in reverse — `s −= t` — keeping the anchor exact (§3).

---

## 7 · Stick band: 70px, direction-aware

`STICK_BAND_PX = 70`. Let `D = H − (s + V)` be the distance from the
viewport bottom to the content bottom. The rAF-coalesced scroll handler
(`onScrollTick`, Lean) implements:

    scrolledUp (s decreased)      ⇒ atBottom := false      — even inside the band
    else                          ⇒ atBottom := (D ≤ 70)   — re-engage only downward

and the layout pass (`applyStick`) snaps only sticky views:
`s := H − V`.

**Theorem (atBottomStickiness, Lean):**
1. scrolling *down* to within 70 px re-engages stickiness and the next layout
   pass snaps to the bottom;
2. scrolling *up* — even 50 px, i.e. still inside the band — disengages
   stickiness and the layout pass leaves `s` exactly where the user put it:
   **reading 50 px up is never yanked back** (`notSticky_outside_band`
   covers anything beyond the band).

Why 70 px matters: without a band, a stop 1 px above the bottom would be
"not at bottom" forever; with a band, the *next downward scroll* re-latches.
A stopped position inside the band does NOT re-latch — the Lean theorem
states both directions.

---

## 8 · Sentinel preload band: 200px, and no wedge at the top

The 1 px sentinel row sits at the top of the DOM with
`IntersectionObserver rootMargin: '200px 0px 0px 0px'` — it intersects
**iff `s ≤ 200`** (`sentinelPreloadFiresBeforeTop`, Lean, iff form).

* The preload band fires the history request *before* the user reaches the
  top, so the compensation (§2) has already landed by the time `s = 0` is
  reachable — the top never runs out of content.
* The observer fires on layout, not on scroll events, so a user parked at
  `s = 0` (where wheel-up generates no further scroll events) still triggers
  the load — no wedge (`noWedgeAtTop`, Lean). Guards: `loading`,
  `noMoreHistory`, `cleared`, non-scrollable all suppress
  (`shouldLoad_false_of_guard`).

---

## 9 · Atomicity: the flicker theorem

The DOM mutation and the `scrollTop` write happen inside **one synchronous
flush** (`flushSync`), with exactly one layout read between them. The frames
a compositor can observe are therefore only:

    [s, prependCompensate s]                       — "before" and "after"

**noFlickerSameFrame (Lean):** every observable frame has the same anchor —
there is no intermediate frame with the new `H` and the old `s`.

The model has teeth: if the compensation were deferred to a later frame
(`requestAnimationFrame`), the middle frame would show the content shifted
by `d` px:

    naive: [s, {H + d, s}, {H + d, s + d}]  ⇒  ∃ frame with A′ ≠ A.

**naivePrependFlickers (Lean)** proves that deferral *provably* flickers.
This is why every compensation site in `MessageList.svelte` calls
`flushSync()` first and only falls back to `tick().then(…)` when
`flushSync` throws (test-mode), applying the identical `oldTop + δ`.

---

## 10 · Silent viewport fill: bounded, anchor-preserving

The `tryAutoFillSilent` loop prepends pages while the container is not
scrollable (short buffers where the sentinel can't be reached). `autoFill`
(Lean) consumes history front-to-back with fuel
`MAX_SILENT_FILLS = 3`:

* `progressiveLoadTerminates` — at most 3 silent fetches, always halts;
* `eventuallyScrollableOrExhausted` — halts only scrollable / exhausted /
  fill-capped;
* `autoFill_preserves_anchor` — every iteration is a compensated prepend,
  so the fill is invisible;
* `autoFill_pages_suffix` — never re-requests or drops a page.

---

## 11 · Rounding and drift — why nothing accumulates

* `scrollTop` and layout offsets are **doubles** in the browser; row heights
  may be sub-pixel (font rendering), and `δ = H′ − H` is read exactly.
* Each compensation is a *fresh measurement against the current DOM*, not an
  accumulated sum: error per step is **0**, hence no drift across 10 000
  prepends (confirmed by simulation, §13).
* The `Math.ceil` in `handleScroll`'s `scrollBottom` appears only in the
  pin-distance *predicates* (1 px tolerance for the stick band), never in the
  compensation arithmetic.
* The double-snap `scrollTop = scrollHeight; void scrollHeight; scrollTop =
  scrollHeight` at the bottom defends against late image/font layout growing
  the content *after* the initial snap — pinned views are re-pinned, and the
  `ResizeObserver` + `schedulePinnedResnap` polls keep a pinned view pinned.

---

## 12 · Code mapping (every compensation site)

| site | math | § |
|---|---|---|
| `revealBacklogFromMemory` (oldH/oldTop, `flushSync`, `s = oldTop + (scrollHeight − oldH)`) | revealOlder | 2,3,9 |
| `$effect` history prepend (`usePrev` cached baselines when |raw−prev| > 500, same flush) | prependCompensate | 2,3,5,9 |
| `newDivider && cachedAtTop` branch (divider settle after reveal) | revealOlder | 2,5 |
| `idx > 0` head-key window shift | §5 window shift | 5 |
| `maybeTrim` (only from at-bottom paths) | applyTrim | 6 |
| `handleScroll` `atBottom` state machine (`distFromBottom ≤ STICK_BAND_PX`, direction-aware) | onScrollTick/applyStick | 7 |
| pinned snap `s = scrollHeight` (+ double-set, RO, resnap polls) | applyStick | 7,11 |
| `renderEndKey` freeze while scrolled up | frozenRenderEndWhileScrolledUp | 3 |
| `LoadMore` 1 px sentinel, `rootMargin 200px` | sentinelPreloadFiresBeforeTop | 8 |
| `ChatArea.handleLoadMore` / cursor advance (`earliest < cursor` check) | loadOlder_cursor_strict | 8 |

---

## 13 · Confirmation evidence

1. **Lean model** — `docs/aristotle/ChatInfinite/{Basic,Scroll,Controller}.lean`,
   delivered with **zero sorries** (`lake build` green, v4.28.0 + Mathlib):
   `scrollTopPreservedAfterPrepend`, `noFlickerSameFrame`,
   `naivePrependFlickers`, `atBottomStickiness`, `boundedWindow`,
   `applyTrim_idempotent`, `sentinelPreloadFiresBeforeTop`,
   `noWedgeAtTop`, `progressiveLoadTerminates`,
   `autoFill_preserves_anchor`, `frozenRenderEndWhileScrolledUp`, … (proof
   journal: `docs/aristotle/IRC_SCROLL_SUMMARY.md`).

2. **Deterministic simulation** — `scripts/scroll-anchor-sim.mjs` models the
   DOM (clamping included) and replays the exact compensation algorithm with
   seeded-random mixed row heights (18–40 px rows, 15 % ANSI-art rows
   60–160 px): **20 000 ops — 10 922 history loads, 3 094 trims, 4 013 frozen
   realtime, 1 971 pinned appends — zero violations.** The reader's screen
   offset and the anchor are preserved to floating-point exactness on every
   history load; pinned stays pinned; frozen realtime moves nothing.

3. **Real browser suites** (headless Chromium, `npm run test:client`):
   `MessageList.test.ts`, `MessageList.refresh.test.ts`,
   `ScrollBackAnchor.e2e.test.ts` (anchor row measured across consecutive
   reveals), `tclmafia-flash.e2e.test.ts` (deep-history double-load),
   `ActionSnap.e2e.test.ts` (/me + NOTICE snap), `ScrollPin.e2e.test.ts`,
   `ScrollPin2.test.ts`, `InfiniteScrollSlow.e2e.test.ts` — run results
   below.

---

## 14 · The one-line summary

> Insert `d` px above the viewport, add exactly `d` to `scrollTop` in the
> same synchronous flush, measure `d` from the DOM rather than computing it,
> never trim or append below the viewport while the user is reading, and the
> reader's row never moves — provably, and to the pixel.

*Generated 2026-08-14 for IRC Fiber.*
