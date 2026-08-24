import ChatInfinite.Controller

/-!
# Verified flicker-free reverse infinite scroll — index

This is the entry point of the specification.  The model lives in three files:

| file                        | content                                                      |
| --------------------------- | ------------------------------------------------------------ |
| `ChatInfinite/Basic.lean`   | buffers, dedup prepend, stable keys, cursor pagination        |
| `ChatInfinite/Scroll.lean`  | scroll geometry, sentinel, stick band, trim, silent fill loop |
| `ChatInfinite/Controller.lean` | the composed controller: realtime + history + invariants   |

The reference TypeScript controller that these proofs describe is
`algorithm.ts`; each exported function there is annotated with the theorem
that justifies it.

## The proved obligations

* `scrollTopPreservedAfterPrepend` — compensated prepend keeps the viewport;
* `noDuplicatesAfterPrepend` — dedup by eid keeps keys unique;
* `noGaps` — consecutive cursor pages tile the history;
* `boundedWindow` — the trim rule bounds the rendered window;
* `atBottomStickiness` — 70px band re-engages downwards, never yanks upwards;
* `sentinelPreloadFiresBeforeTop` — 200px rootMargin preload band;
* `progressiveLoadTerminates` — the silent fill loop is bounded;
* `noFlickerSameFrame` — the prepend frame sequence has a constant anchor;
* `eventuallyScrollableOrExhausted` — liveness of the fill loop.

Supporting results (same files): `prependDedup_idempotent` (no double render of
a batch), `stableKeyUnchangedByPrepend` (ANSI-art rows are not recreated),
`paginationMeasureDecreases` and `loadOlder_cursor_strict` (no phantom cursor
stall), `noWedgeAtTop` (no sentinel wedge at `scrollTop = 0`),
`naivePrependFlickers` (the deferred-compensation implementation really does
flicker), `noDroppedRealtime`, `frozenRenderEndWhileScrolledUp`,
`flushPendingDelivers`, `realtimeCommutesWithHistoryLoad`,
`applyTrim_idempotent`, `windowBoundInvariant`, `loadOlder_invariant`.
-/

alias scrollTopPreservedAfterPrepend := ChatInfinite.scrollTopPreservedAfterPrepend
alias noDuplicatesAfterPrepend := ChatInfinite.noDuplicatesAfterPrepend
alias noGaps := ChatInfinite.noGaps
alias boundedWindow := ChatInfinite.boundedWindow
alias atBottomStickiness := ChatInfinite.atBottomStickiness
alias sentinelPreloadFiresBeforeTop := ChatInfinite.sentinelPreloadFiresBeforeTop
alias progressiveLoadTerminates := ChatInfinite.progressiveLoadTerminates
alias noFlickerSameFrame := ChatInfinite.noFlickerSameFrame
alias eventuallyScrollableOrExhausted := ChatInfinite.eventuallyScrollableOrExhausted
