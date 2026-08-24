# Summary of changes for run c02e4c7b-212d-4aee-afe6-dd1b23190a95
Delivered a Lean 4 (v4.28.0 + Mathlib) verified specification of the reverse infinite-scroll algorithm plus the matching reference TypeScript controller. `lake build` succeeds with no `sorry`; the proofs use only the standard axioms (`propext`, `Classical.choice`, `Quot.sound`).

**Files**
- `ChatInfiniteScroll.lean` — index; exposes the nine required obligations under their requested top-level names.
- `ChatInfinite/Basic.lean` — messages, ordered buffers, deduplicated prepend, stable render keys, cursor pagination.
- `ChatInfinite/Scroll.lean` — `ScrollState` (exactly the requested fields), sentinel, stick band, trim, silent viewport-fill loop.
- `ChatInfinite/Controller.lean` — the composed controller: realtime queueing, frozen render end, history loads, invariants.
- `algorithm.ts` — Svelte 5 runes reference controller (no external dependency), each step annotated with the theorem justifying it; type-checks under `tsc --strict` with the DOM lib.
- `README.md` — map of the development and of every proved statement.

**Proved (all requested, plus liveness)**
- `scrollTopPreservedAfterPrepend` — prepending k rows worth d px with `scrollTop' = scrollTop + d` keeps the anchor, the distance from the bottom, and the previously rendered rows.
- `noFlickerSameFrame` — every observable frame of the atomic prepend has the same anchor. To show the model is not vacuous, `naivePrependFlickers` proves that deferring compensation to a later frame really does expose a jumped frame.
- `noDuplicatesAfterPrepend`, plus `prependDedup_idempotent` (replaying a page is a no-op ⇒ no double render) and `stableKeyUnchangedByPrepend` (bottom-counted keys survive prepends, so heavy rows are not recreated).
- `noGaps` — consecutive cursor pages tile the history; with `cursorStrictlyAdvances`, `paginationMeasureDecreases`, `loadOlder_cursor_strict` (strict cursor progress ⇒ no phantom stall) and `pageBefore_eq_nil_of_not_hasMore` (`hasMore = false` hides LoadMore).
- `boundedWindow`, `applyTrim_idempotent`, `windowBoundInvariant` — the window stays ≤ 350 rows, trim is a no-op when re-run, and the bound is preserved by append+trim.
- `atBottomStickiness` — downward motion into the 70px band re-engages the snap; upward motion inside the band disengages it and the layout pass leaves `scrollTop` untouched (no yank). `notSticky_outside_band` covers outside the band.
- `sentinelPreloadFiresBeforeTop` (iff form: intersects exactly when `scrollTop ≤ 200`), `noWedgeAtTop`, `shouldLoad_false_of_guard`.
- `progressiveLoadTerminates`, `eventuallyScrollableOrExhausted`, `autoFill_preserves_anchor`, `autoFill_pages_suffix` — the silent fill loop is bounded by `MAX_SILENT_FILLS`, halts scrollable/exhausted/capped, is anchor-preserving, and never re-requests or drops a page.
- Realtime: `noDroppedRealtime`, `frozenRenderEndWhileScrolledUp` (no geometry change, frozen render end while scrolled up), `renderEndAdvancesAtBottom`, `flushPendingDelivers`, `realtimeCommutesWithHistoryLoad`, and `loadOlder_invariant` (a history load preserves well-formed geometry, buffer order, dedup and the cursor lower bound while keeping the anchor).

**Scope note.** These are statements about the model: the runtime behaviour claims in the brief (no flicker at 120Hz, no phantom stalls, synchronous compensation) hold for the modelled algorithm — atomic same-flush compensation, bounded window, strictly decreasing cursor — but no browser measurement was performed here. The rejection rationale for `svelte-infinite-loading` (Svelte 3/4 slot API, no reverse primitive, no windowing, no scrollTop compensation, no stick band, unmaintained) is recorded at the top of `algorithm.ts` and in the README. The original `SPEC.md` is unchanged; the earlier placeholder statements in `ChatInfinite/Scroll.lean` (several of which were trivially true, e.g. `h → h` forms) were replaced by the substantive versions above.