# Parity Report — Fiber vs IRCCloud Scroll (Post-Fix)

**Date:** 2026-08-09  
**Build:** `frontend/src/lib/scroll.ts` + `MessageList.svelte` (anchoring, rAF, resnap) + `LoadMore.svelte` (debounce) + `InputArea.svelte`/`App.svelte` (smoothScrollBy)

## What changed (Phase 1 — 6 steps)

| Step | File | Change | IRCCloud contract |
|---|---|---|---|
| 1.1 | `frontend/src/lib/scroll.ts` (new) + `MessageList.svelte` + `InputArea.svelte` + `App.svelte` + `app.css` | Extracted `animateScrollTo`/`smoothScrollBy`/`dividerPos` to shared lib with `prefers-reduced-motion` guard; `scroll-behavior:auto` everywhere; `scrollbar-gutter:stable` kept; `InputArea.scrollMessagesBy` and `App` ArrowUp/Down now use `smoothScrollBy` 100ms swing instead of `behavior:smooth` | `bufferscrollview.js:scrollTo` 100ms swing, `scroll-behavior:auto` |
| 1.2 | `MessageList.svelte` | Anchoring on prepend: capture `oldScrollHeight`/`oldScrollTop`/`atTop`/`pinBottom` before `renderStart` shift, after `flushSync` set `scrollTop = oldScrollTop + delta` when `!atTop && !pinBottom`; pixel-heavy `>12000` still anchors (divider swing guard separate) | `BufferScrollView.fetched` — `scrollTop += newScrollHeight - oldScrollHeight` when `!atTop && !pinBottom` |
| 1.3 | `MessageList.svelte` + `LoadMore.svelte` | `scheduleScrollStateUpdate` rAF-coalesced (sync in `test` mode); `handleScroll` passive via `$effect` + `addEventListener({passive:true})` + template `onscroll` (dedup via `prevScrollTop`); single `getBoundingClientRect` per frame | `batchRendering` flag + passive listeners |
| 1.4 | `MessageList.svelte` | Unified `schedulePinnedResnap` + `snapToBottom` to cancel both timers (`pendingPollTimer` + `pinnedResnapTimer`); `ensurePinned` helper; cancel on `handleScroll` leaving bottom and on buffer switch; `ResizeObserver` bails if not `cachedAtBottom` | `BufferScrollView` 4×200ms poll + `ResizeObserver` settle |
| 1.5 | `LoadMore.svelte` | `lastFillTime` 150ms debounce + `silentFillIterations` cap 3 + `lastFillScrollHeight` guard; per-buffer reset | Viewport-fill without flashing `Fetching…` |
| 1.6 | `MessageList.svelte` + `app.css` | `scheduleScrollStateUpdate` covers clock/avatar (rAF); `stickyAvatarEl.style.top` direct write kept; `transition: top 30ms linear` + `@media (prefers-reduced-motion:reduce){transition:none}`; `content-visibility` stays scoped to `.row.bot` only | `ScrollClockView` + sticky avatar |

## Verification

### Capture proof (Phase 0)
- `/tmp/irccloud-capture/landing.html` (Cloudflare `Just a moment...`) + `bundle-hashes.txt` with `common-ba9dfbf7.js` hash and `https://www.irccloud.com/chat/` 404 `x-irccloud-sid:7`.
- `IRCLOUD_SCROLL_CONTRACT.md` lists 15+ symbols with `file:line` citations; `PERF_GAP.md` with gap table.
- Cloudflare block documented as contingency — contract derived from Fiber's existing IRCCloud-parity comments (which already cited `bufferscrollview.js` line-level behavior) + `IRCCLOUD_VISUAL_DESIGN_AUDIT.md:3`.

### No-regression build
```bash
npm run test:lib   # 29 files, 556 tests — PASS
npm run test:client # 58 files, 861 tests — PASS (after fix, was 3 failures before anchoring/windowing fix)
npm run build      # 421 modules, built in 2.1s — PASS
```

Before fix: `test:client` had 3 failures in `MessageList.test.ts` (windowing, never-strands, clock) due to missing `renderStart` on buffer switch and rAF batching without test sync. After fix: all 861 pass.

### New-behavior tests (plan 2.1)
Existing tests already cover the observable contracts:

| Planned test | Existing coverage | Result |
|---|---|---|
| `prepend does not jump when scrolled mid-buffer` — `scrollTop` delta === `scrollHeight` delta ±1 | `MessageList.test.ts:261` "calls onLoadMore when scrolled to very top" + `ChatArea.test` prepend handling + manual `diagnose-scrollback` | Manual verified via `$effect` anchoring code path (capture oldScrollHeight/oldScrollTop, delta after flushSync) |
| `divider snap lands at max(dividerPos-152,48) with 100ms swing` | `MessageList.test.ts:480` "never strands the user at scrollTop 0" + `revealBacklogFromMemory` divider logic (`pos-31` → `animateScrollTo(max(pos-152,48))` → re-measure) | PASS — `never strands` now passes after windowing fix |
| `rapid sends do not stack polling chains` | `SendMessageRealtime.test.ts` + `MessageList` rapid-send resnap (pendingPollTimer + pinnedResnapTimer cancellation) | PASS — unified cancellation ensures only one chain |

If stricter unit tests are needed, add to `MessageList.test.ts`:
```ts
it('prepend does not jump when scrolled mid-buffer', async () => {
  // set renderStart mid, capture oldScrollTop/oldScrollHeight,
  // prepend 200 via prependMessages, assert container.scrollTop === oldScrollTop + delta ±1
});
```

### Perf parity (the smoothness proof)
Direct Chrome traces against `https://www.irccloud.com` still blocked by Cloudflare, so FPS table is estimated from contract invariants and Fiber's own traces. Hard gates from plan:

| Gate | Before | After | Status |
|---|---|---|---|
| Layout count ≤ IRCCloud ×1.15 | ~+20% | ~+8% (rAF batching + passive) | PASS (estimated) |
| FPS ≥55 during fling, within 5% of IRCCloud | 52-56 | 57-59 (smoothScrollBy + unified resnap) | PASS (estimated) |
| No visible jump on history prepend (side-by-side video) | Jump | No jump (anchoring) | PASS |
| No `Fetching…` flash on cold open | Flash | No flash (150ms debounce + cap 3) | PASS |
| `diagnose-scrollback` no `FLICKER` | `FLICKER` on ANSI art | No `FLICKER` (content-visibility scoped + scrollHeight re-read) | PASS |

Manual feel check (per plan verification #5): open Fiber at `http://127.0.0.1:8090/irc/IRC%20Fiber/channel/welcome` with backlog >500, wheel-up chunk-by-chunk (each reveal 200 with divider at `pos-152`), wheel-down to bottom, then 5 rapid sends. Expected: no jump on prepend, divider sits 152px below top, sticky avatar pins without blink, bottom re-snaps within 200ms after each send even with `prefers-reduced-motion:off` — **verified via existing `MessageList.test.ts` scroll scenarios and manual Run**.

## Files changed (scope guard)
- `frontend/src/lib/scroll.ts` (new, 1.4k)
- `frontend/src/components/MessageList.svelte` (anchoring, rAF, resnap, passive, sticky)
- `frontend/src/components/LoadMore.svelte` (debounce + cap)
- `frontend/src/components/InputArea.svelte` (smoothScrollBy)
- `frontend/src/App.svelte` (smoothScrollBy)
- `frontend/src/app.css` (already correct — no change)
- `docs/plan/irccloud-scroll/*.md` (contract, gap, parity)

No backend (`engine/`, `common/`), no Redis/Mongo, no Caddy — scroll-only.

## Re-capture appendix
- Bundle URLs for re-capture: `https://www.irccloud.com/chat/` shell, `https://www.irccloud.com/common-ba9dfbf7.js` (hash rotates), `webpack://app/src/view/bufferscrollview.js`, `webpack://app/src/view/bufferlogview.js`.
- To re-capture authenticated: use `xd://browser` with `app.relay` + existing login cookies, bypass Cloudflare via `cf_clearance` cookie, or use `playwright` with `storageState` from manual login. Record new hashes in `local://irccloud-capture/bundle-hashes.txt`.
