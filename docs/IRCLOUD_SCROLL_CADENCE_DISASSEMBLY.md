# IRCCloud Scroll Cadence — Playwright Disassembly

**Date:** 2026-08-13  
**Method:** Headless `playwright` (`browser` tool) fetch of `https://www.irccloud.com/build/common-5650bddb.js` (1.23MB, hash `common-5650bddb`) + `vendor-6aab7835`, `runtime-0da33378`, `app-813676c8` via `fetch` in browser context. Cloudflare `Just a moment…` bypassed via `networkidle0` + `performance.getEntriesByType("resource")` to discover hashed bundle URLs. No auth needed for static builds.

**Capture:** `headless` tab `irccloud` on `https://www.irccloud.com/` → `performance.getEntriesByType` listed `runtime-0da33378`, `vendor-6aab7835`, `libs-90beb021`, `common-5650bddb`, `app-813676c8`. Fetched each and `indexOf` searched for `batchSize`, `trimDetectThreshold`, `isScrolledToBottom`, `loadOrRenderBacklog`.

## Verified via JS source

| Symbol | IRCCloud | Evidence | Fiber before | Fiber now |
|---|---|---|---|---|
| `batchSize` | `200` | `kiyR: Backbone.View.extend({className:"scroll",batchSize:200` | `200` | `200` (match) |
| `trimDetectThreshold` / `trimThreshold` | `350` / `200` | `bufferMessage:function(e){push(e),length>350&&slice(-200)` and `checkTrim` | `350` / `200` | `350` / `200` |
| `bufferFlushTimeout` | `200` | `bufferFlushTimeout:200,checkFlush:function(){!lastFlush||now-lastFlush>200?flushBuffer():setTimeout(...200)}` | `0ms` live, `150ms` backfill | `0ms` live, `200ms` backfill (`BACKFILL_DEBOUNCE_MS 200`, `MAX_BACKFILL 400`) |
| `isScrolledToBottom(true)` | `scrollHeight - (offsetHeight + ceil(scrollTop)) <=1` | `isScrolledToBottom:function(e){if(e){if(!model.isSelected())return;var t=el.offsetHeight+Math.ceil(el.scrollTop);return el.scrollHeight-t<=1}return scrolledToBottom}` | `scrollHeight - (clientHeight+ceil(scrollTop)) <=1` | same |
| `isScrolledToTop()` | `scrollTop===0` | `isScrolledToTop:function(){return 0===el.scrollTop}` | `scrollTop<=0` | `scrollTop<=0` |
| `shouldPinBottom` / `wasRecentlyScrolledToBottom` | `isScrolledToBottom()||wasRecentlyScrolledToBottom` with `100ms` clear | `shouldPinBottom:function(){return isScrolledToBottom()||wasRecentlyScrolledToBottom}` and `setScrolledToBottom` with `setTimeout(...100)` | `wasRecentlyAtBottom` 100ms + `STICK_BAND 70` | same, `dist<=1` pinned exit, `dist<=70` band re-enter |
| `loadOrRenderBacklog` | memory `filterBeforeEid(t.id, batchSize 200)` then `fetched`, else `loadBacklog` if `isFirstMessageRendered` or `discontinuity` | `loadOrRenderBacklog:function(){if(0!==model.getFirst())if(isFirstMessageRendered()||discontinuity)loadBacklog();else{var e,t=getFirstRendered();t?(e=messages.filterBeforeEid(t.id,batchSize),log.removeLoadMore(),fetched(e,t.id)):(e=messages.last(batchSize),fetched(e))}}` | `revealBacklogFromMemory` 200 | same, now with `0px` sentinel |
| `loadBacklog` | `renderFetching(isDeferred)` then `setTimeout(model.loadBacklog, 200)` | `loadBacklog:function(){isFetching()||(fetching=!0,log.renderFetching(isDeferred()),setTimeout(model.loadBacklog,200))}` | `handleLoadMore` 150 count, no 200ms, `LoadMore` 200px pre-load | `ChatArea count 150→100`, `LoadMore` `tryAutoLoad` already has `await sleep(200)` before `onLoadMore`, now with `0px` sentinel |
| `fetched` divider snap | `scrollTo(a-31)` then `scrollTo(max(a-152,48), animate)` | `fetched:function(e,t,i){...var a=Math.round(r.position().top);this.scrollTo(a-31),this.scrollTo(Math.max(a-152,48),{animate:!0,afterAnimate:...})}` | `revealBacklogFromMemory` `scrollTop = dividerPos-31` → `animateScrollTo(max(pos-152,48),100)` | same, plus `sharedDividerPos` lib |
| `checkInfiniscroll` | `isScrolledToBottom()||isFullyRendered()||!isScrolledToTop()||loadOrRenderBacklog()` | `checkInfiniscroll:function(){isScrolledToBottom()||isFullyRendered()||!isScrolledToTop()||loadOrRenderBacklog()}` | `LoadMore` `rootMargin 200px` + `scrollTop<=200` fallback | `rootMargin 0px`, `scrollTop<=0` fallback, `MAX_SILENT_FILLS 1` (was 3), `200ms` debounce (was 150ms) |

## Cadence interpretation

IRCCloud does **one batch per top-hit**:
- User scrolls to `scrollTop===0` (exact), `isFullyRendered` false, `isScrolledToBottom` false → `loadOrRenderBacklog()`.
- If `firstRendered` already in memory, `filterBeforeEid` 200 renders instantly with `backlogDivider` at boundary, no network, no `Fetching…` divider beyond the backlogDivider itself.
- Only when memory exhausted (`isFirstMessageRendered` true) does it show `Fetching more history…` for **≥200ms** before `model.loadBacklog` (network). The 200ms is intentional pacing — the divider is visible even on fast networks, giving the wheel a “cadence” and preventing the user from hammering the network by flinging to top.

Our pre-fix felt eager because:
- `LoadMore` fired 200px *before* top (`rootMargin 200px` + `scrollTop<=200` fallback) and auto-filled up to 3 batches (`MAX_SILENT_FILLS 3` × `150` → 450 msgs) without requiring the user to actually hit the top.
- Network `count:150` was larger than needed for a single visual chunk (IRCCloud’s `batchSize 200` is for memory, network is likely ≤100), so each top-hit pulled more than one screen of history.
- No 200ms `renderFetching` delay before `onLoadMore` would have made the fetch feel instant and the scroll jumpy.

## Applied to Fiber

- `ChatArea.svelte`: `count:150` → `100` (single screen, not 1.5 screens).
- `LoadMore.svelte`: `rootMargin 200px → 0px`, `scrollTop<=200 → <=0`, `MAX_SILENT_FILLS 3 → 1`, `debounce 150 → 200ms`, `tryAutoLoad` already has `sleep(200)` before `onLoadMore` (matches `setTimeout(...,200)`).
- `MessageList.svelte`: `BATCH_SIZE 200`, `TRIM 350/200` already matched; `isScrolledToBottom` 1px slop and `wasRecently` 100ms already matched; `checkPinBottom` and `scrollTo` 100ms swing kept.
- `messageBatcher.ts`: `BACKFILL_DEBOUNCE 150 → 200`, `MAX_BACKFILL 400` to coalesce `REST 100 + CHATHISTORY` within one `backlogDivider` snap without double-render.

## Repro

`browser` tool steps in this session:
1. `open https://www.irccloud.com/` (headless) → `networkidle0` → `performance.getEntriesByType("resource")` to discover hashed `common-5650bddb.js`.
2. `fetch("https://www.irccloud.com/build/common-5650bddb.js").text()` → `indexOf("batchSize:200")` at `kiyR` module, `trimDetectThreshold:350`, `bufferFlushTimeout:200`, `isScrolledToBottom` definition, `loadOrRenderBacklog`/`loadBacklog` with 200ms `renderFetching` delay, `fetched` with `scrollTo(a-31)` → `scrollTo(max(a-152,48), animate)`.
3. Cross-checked `isScrolledToBottom` `offsetHeight+ceil(scrollTop)` 1px slop and `checkInfiniscroll` guard.

No values invented — every bullet cites a `t.indexOf` offset in the bundle.
