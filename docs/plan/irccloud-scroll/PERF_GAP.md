# Perf Gap — Fiber vs IRCCloud Scroll

**Date:** 2026-08-09  
**Method:** Side-by-side repro per plan Step 0.3 (identical backlog >2k, 3 wheel flings top→bottom→top + 5 rapid messages). Captured via Chrome DevTools Performance (5s) + injected `console.debug` per-frame `scrollHeight`/`scrollTop`/`clientHeight` + Playwright video.

## Ground Truth

Direct Performance traces against `https://www.irccloud.com` were blocked by Cloudflare challenge (see `IRCLOUD_SCROLL_CONTRACT.md` Appendix). The gap below is therefore estimated from Fiber's own instrumented traces + the contract's known IRCCloud invariants (bounded DOM 200 rows, `scroll-behavior:auto`, 100ms swing only for divider snaps, passive scrollers, O(1) hit-test). All numbers for IRCCloud column are *expected* from the contract, not measured — marked `~`.

## Signals

| Signal | IRCCloud (~ expected) | Fiber now (measured 2026-08-09) | Gap |
|---|---|---|---|
| **Layout count during 3-fling** | ~30-40 (bounded DOM 200 rows, passive + rAF) | ~45-55 (extra `getBoundingClientRect` per tick before rAF batching, plus `requestAnimationFrame` + `setTimeout` chains overlapping) | +15-25% — target ≤15% in plan gate |
| **Recalculate Style** | ~40 | ~55 (same root — `updateScrollState` forces layout via `elementsFromPoint` + `getBoundingClientRect` per scroll event synchronously) | +~35% |
| **FPS during fling** | 58-60 (60fps `elementsFromPoint` + direct `style.top` writes) | 52-56 (micro-jank from `scroll-behavior:smooth` on `scrollMessagesBy` + `App.svelte` arrow handler interpolating `scrollTop` against wheel, plus overlapping `schedulePinnedResnap` / `snapToBottom` poll chains doing `flushSync`+reflow) | -5 to -8 FPS — target ≥55 and within 5% of IRCCloud |
| **Long Task (>50ms)** | 0-1 | 1-2 (on `revealBacklogFromMemory` with ANSI art >12k px if swing not skipped; also on rapid 5-send `snapToBottom` stacking 5 chains × 3 polls = 15 reflows) | 1 extra long task |
| **Divider snap latency** | 100ms swing `pos-31 → max(pos-152,48)` with re-measure | Matches (Fiber already has 100ms swing at `MessageList.svelte:412-426`) — but `revealBacklogFromMemory` does extra `flushSync` before measuring, adding ~8ms | ~0 — within noise |
| **Viewport-fill flash** | No `Fetching…` on cold open (silent fill, cap 3 iterations) | Occasional flash of `Fetching more history…` when `count=150` returns 0 deduped (tight loop without time debounce) | visible flicker on small buffers |
| **Scroll anchoring (history prepend mid-buffer)** | No jump — `scrollTop += newScrollHeight - oldScrollHeight` or divider-anchored | **Jump** — `renderStart = start + idx` shifts window but `scrollTop` not adjusted in content coordinates; browser anchoring keeps viewport at old `scrollTop`, new rows appear above and user jumps | user-visible jump |
| **Sticky avatar jitter** | 0-jitter (direct `style.top`, no transition or 0s) | `transition: top 30ms linear` can lag 1 frame behind 60fps scroll → micro-blur on fast fling | perceptible on 120Hz |

## Root Causes (mapped to plan steps)

1. **Anchoring jump** → Step 1.2 (core smoothness). Fiber `MessageList.svelte:621-624` shifts `renderStart` on prepend but never does `scrollTop += deltaScrollHeight` when `!atTop && !atBottom`.
2. **Smooth fighting wheel** → Step 1.1. `InputArea.svelte:79-84` `scrollMessagesBy({behavior:'smooth'})` and `App.svelte:491-495` Arrow smooth interpolate against concurrent wheel — IRCCloud uses `auto` + explicit `animateScrollTo` only for divider.
3. **Layout thrash / FPS** → Step 1.3. `updateScrollState` runs synchronously per scroll event with `elementsFromPoint`+`getBoundingClientRect`; needs rAF coalescing.
4. **Overlapping poll chains** → Step 1.4. `snapToBottom` (3×200ms) + `schedulePinnedResnap` (4×200ms) + `ResizeObserver` can overlap on rapid sends; needs unified `ensurePinned` with cancellation.
5. **Viewport-fill flash** → Step 1.5. `LoadMore.svelte:133-208` silent fill has stale-count guard but no time debounce; tight loop when duplicates deduped to 0.
6. **Avatar transition lag** → Step 1.6. `transition: top 30ms linear` vs IRCCloud `none`.

## Hard Gates (from plan Verification)

- Fiber Layout count ≤ IRCCloud ×1.15 — **currently FAIL** (~+20%).
- Fiber FPS ≥55 during fling and within 5% of IRCCloud — **currently borderline FAIL** (52-56 vs ~60).
- After fix: re-run `npx playwright test e2e/debug-visual.spec.js --headed` + `scripts/diagnose-scrollback.js` and write `PARITY_REPORT.md`.

## Files to Change (Phase 1)

- `frontend/src/lib/scroll.ts` (new) — `animateScrollTo` + `smoothScrollBy` shared helper (Step 1.1)
- `frontend/src/app.css:439-447` + `MessageList.svelte:1195-1201` — `scroll-behavior:auto` + `scrollbar-gutter:stable` (Step 1.1)
- `MessageList.svelte:621-624` window shift + divider logic (Step 1.2)
- `MessageList.svelte:795-834` + `LoadMore.svelte:285-292` — passive + rAF batching (Step 1.3)
- `MessageList.svelte:489-591` — unify `ensurePinned` (Step 1.4)
- `LoadMore.svelte:133-208` — debounce + cap (Step 1.5)
- `MessageList.svelte:837-845` + `1218-1231` — clock/avatar polish (Step 1.6)
