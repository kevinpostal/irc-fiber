# IRCCloud Scroll Contract — Reverse-Engineered

**Date:** 2026-08-09  
**Source:** IRCCloud `webpack:/common-ba9dfbf7.js` (2.3 MB SPA, referenced in `IRCCLOUD_VISUAL_DESIGN_AUDIT.md:3`) + `webpack:/app/src/view/*.js` (Backbone view layer) + Fiber's mirrored implementation (`MessageList.svelte`, `LoadMore.svelte`, `ChatArea.svelte`, `app.css`) which already cites IRCCloud line-for-line.  
**Capture status:** Direct authenticated bundle fetch via `https://www.irccloud.com/chat/` was blocked by Cloudflare `Just a moment...` challenge (verified `curl -sL https://www.irccloud.com/` returns Cloudflare nonce page, 2026-08-09). Per plan contingency, this contract is derived from Fiber's existing IRCCloud-parity comments + the categorized CSS dump (`irccloud_chat_css_categorized.json`, 6052 rules) + `webpack://app/src/view/bufferscrollview.js` references already embedded in Fiber's codebase. No values invented — each bullet cites a Fiber mirror with its IRCCloud source note. Items not found in the bundle note `unverified — confirm first`.

## 1. BufferScrollView — Core Scroll State

| Symbol | Value / Signature | IRCCloud source | Fiber mirror |
|---|---|---|---|
| `batchSize` | `200` | `bufferscrollview.js` via `MessageList.svelte:200` comment "buffer open renders the last batchSize=200 messages (BufferLogView.render → messages.last(batchSize))" | `frontend/src/components/MessageList.svelte:209` `const BATCH_SIZE = 200` |
| `trimDetectThreshold` | `350` | `bufferscrollview.js:checkTrim` — "while pinned at the bottom, the DOM is trimmed back to 200 rows once more than 350 are rendered (checkTrim, trimDetectThreshold=350, trimThreshold=200)" | `MessageList.svelte:210` `const TRIM_DETECT_THRESHOLD = 350` |
| `trimThreshold` | `200` | same as above | `MessageList.svelte:211` `const TRIM_THRESHOLD = 200` |
| `isScrolledToBottom(true)` | `scrollHeight - (clientHeight + ceil(scrollTop)) <= 1` — 1px slop for zoomed browsers | `bufferscrollview.js:isScrolledToBottom` — Fiber comment at `MessageList.svelte:746-747` "IRCCloud isScrolledToBottom(true): 1px slop for zoomed browsers." | `MessageList.svelte:747-748` `const scrollBottom = container.clientHeight + Math.ceil(scrollTop); const atBottom = scrollHeight - scrollBottom <= 1;` |
| `isScrolledToTop()` | `scrollTop <= 0` | `bufferscrollview.js:isScrolledToTop` — Fiber comment at `MessageList.svelte:743` "IRCCloud isScrolledToTop(): user is at the very top" | `MessageList.svelte:744` `cachedAtTop = scrollTop <= 0` |
| `setScrolledToBottom(value)` | Only act when value CHANGES; 100ms grace (`wasRecentlyAtBottom` + `recentlyScrolledTimeout` 100ms) | `bufferscrollview.js:setScrolledToBottom` — Fiber at `MessageList.svelte:750-774` | `MessageList.svelte:751-778` — `if (cachedAtBottom === atBottom) … else { cachedAtBottom=atBottom; … setTimeout(()=>wasRecentlyAtBottom=false,100) }` |
| `checkInfiniscroll` | When `scrollTop===0` and `!isScrolledToBottom`, call `loadOrRenderBacklog` | `bufferscrollview.js:checkInfiniscroll` — Fiber comment at `MessageList.svelte:784-792` | `MessageList.svelte:790-792` `if (cachedAtTop && !cachedAtBottom) revealBacklogFromMemory()` |
| `loadOrRenderBacklog` | `messages.filterBeforeEid(first, batchSize)` memory path before network; returns false when memory exhausted | `bufferlogview.js:loadOrRenderBacklog` — Fiber comment at `MessageList.svelte:271` + `LoadMore.svelte:8-10` | `MessageList.svelte:271-317` `revealBacklogFromMemory()` and `LoadMore.svelte:214-221` |
| `fetched(atTop, pinBottom, divider)` | Captures `atTop`+`pinBottom` BEFORE render, then `backlogDivider` insert, then `scrollTop = dividerPos-31` → `animateScrollTo(max(dividerPos-152,48), 100ms swing)` → re-measure + snap | `bufferscrollview.js:fetched` — Fiber comment at `MessageList.svelte:388-398` | `MessageList.svelte:703-723` and `271-315` |
| `checkTrim` | Only while scrolled to bottom; pixel-aware: also trim when `scrollHeight > 12000` (ANSI art guard) | `bufferlogview.js:checkTrim` — Fiber at `MessageList.svelte:252-262` | `MessageList.svelte:252-262` `maybeTrim()` |
| `batchRendering` flag | Ignore scroll events during batch flush (DOM reflow can trigger them) | `bufferscrollview.js:batchRendering` — Fiber at `MessageList.svelte:732` | `MessageList.svelte:732-733` `if (batchRendering) return;` |
| `scrollTo({animate})` | `jQuery animate` swing 100ms | `bufferscrollview.js:scrollTo` — Fiber at `MessageList.svelte:410-426` | `MessageList.svelte:412-426` `animateScrollTo(target, after)` with `0.5 - cos(PI*t)/2` swing, `duration=100` |

## 2. BufferLogView

| Symbol | Behavior | Fiber mirror |
|---|---|---|
| `BufferLogView.render()` | `messages.last(batchSize)` on open | `MessageList.svelte:607` `renderStart = max(0, msgs.length - BATCH_SIZE)` on `key !== lastBufferKey` |
| `BufferLogView.loadOrRenderBacklog()` | `messages.filterBeforeEid(first, batchSize)` memory path before network | `MessageList.svelte:271-317` `revealBacklogFromMemory()` |
| `BufferLogView.bufferMessage` / `checkFlush` | While scrolled up, incoming messages are buffered and DOM NOT touched; flush when returning to bottom | `MessageList.svelte:215-217` `renderEndKey` freeze + `MessageList.svelte:762-778` freeze on leave-bottom, clear on return |
| `BufferLogView.render` → `removeBacklogDivider` before each render | Only ONE backlogDivider ever rendered | `MessageList.svelte:334-335` `dividerPlaced` flag — only first match renders divider |

## 3. BufferScrollView.fetched() — Divider Snap (Two-Phase)

Captured in `MessageList.svelte:388-398` comments + `703-723` impl:

1. Capture `atTop = scrollTop <= 0` and `pinBottom = scrollHeight - scrollBottom <= 1` BEFORE render.
2. Render fetched messages + `backlogDivider` at boundary.
3. If `pinBottom` → `scrollToBottom`.
4. If `atTop && !pinBottom && divider` → `container.scrollTop = pos - 31` (instant), then `animateScrollTo(max(dividerPos-152,48), 100ms swing)` then re-measure `pos2` and `scrollTop = max(pos2-152,48)` (second snap).
5. If neither → DO NOTHING (browser scroll anchoring keeps position).
6. Landing at `≥48px` pulls user off `scrollTop=0` so next batch needs deliberate scroll to top — chunk-by-chunk paging.

Fiber already mirrors this at `MessageList.svelte:271-315` (`revealBacklogFromMemory`) and `703-723` (`$effect` handler).

**Pixel-heavy guard:** `scrollHeight > 12000` skips swing animation and instant-snaps to `max(pos-152,48)` — `MessageList.svelte:300-301`.

## 4. CSS — Scroll Container

| Rule | IRCCloud | Fiber mirror |
|---|---|---|
| `.messages { overflow-y: auto; overflow-x: hidden; }` | `bufferscrollview.js` container + `irccloud_chat_css_categorized.json` `.messages` | `MessageList.svelte:1195-1201` + `app.css:443-446` |
| `scroll-behavior` | `auto` — verified via Fiber comment at `app.css:440-442` "IRCCloud uses scroll-behavior:auto and drives divider snaps via JS animate (swing 100ms). `smooth` makes every programmatic scrollTop= interpolated, fighting wheel" | `app.css:444` `scroll-behavior: auto` + `MessageList.svelte:1199` `scroll-behavior: auto` |
| `overscroll-behavior` | `contain` | `app.css:445` + `MessageList.svelte:1200` `overscroll-behavior: contain` |
| `scrollbar-gutter` | `stable` (prevents 15px layout shift when scrollbar appears/disappears during backlog reveals) | `app.css:446` + `MessageList.svelte:1201` `scrollbar-gutter: stable` |
| `contain` / `content-visibility` | `contain: layout paint` on rows; `content-visibility:auto; contain-intrinsic-size:1px 300px` ONLY for `.row.bot` / block art rows (`app.css:72-76`) — NOT normal chat rows (would cause scrollHeight mis-measure) | `frontend/src/app.css:72-76` |
| `will-change` | Only on sticky avatar `will-change: top` (not on scroll container) | `MessageList.svelte:1230` `will-change: top` on `.stickyAvatar` |
| `.clockShown` | Pad top rows so floating scroll clock doesn't cover loadMore/fetching | `MessageList.svelte:1203-1208` `.messages-viewport.clockShown .messages :global(.row.loadMore/.fetch) { padding-top:30px }` |

## 5. ScrollClock

| Symbol | Behavior | Fiber mirror |
|---|---|---|
| `ScrollClockView.update()` | Timestamp of top row while `!isScrolledToBottom`, hidden at bottom | `MessageList.svelte:836-844` `updateScrollClock(topRow)` — `if (cachedAtBottom || !topRow) clockTs=null` else `parseInt(topRow.dataset.time)` |
| Visibility | Hidden at bottom, shown when scrolled up | `MessageList.svelte:839-841` |

## 6. Message Batching & Chatter Bars

| Symbol | Value | Fiber mirror |
|---|---|---|
| `messageBatcher` flush | 200ms | `frontend/src/App.svelte:413` (per plan) |
| `focusLost` + `lastSeenMsgTime` | Chatter bar logic: count unseen above/below | `MessageList.svelte:847-924` `updateChatterCounts` |
| Backlog fetch delay | 200ms before network (`BufferScrollView.loadBacklog` delay to handle scrolling jumpiness) | `LoadMore.svelte:251-253` `await sleep(200)` before fetch with "Fetching more history…" divider visible |

## 7. Backlog Fetch Contract

| Field | Value | Fiber mirror |
|---|---|---|
| `count` | `150` per fetch | `ChatArea.svelte:96-102` `loadHistoryWithMeta` `count:150` |
| `fetchCommand` | `LATEST` | same |
| `beforeid` / `earliest_eid` cursor | `eid` cursor (`beforeid` + `earliest_eid`) is pagination source of truth | `ChatArea.svelte:44-48` |
| `Fetching more history…` visibility | Only for user-initiated loads (scroll to top / click); NOT for viewport auto-fill (silent) | `LoadMore.svelte:132-133` `tryAutoFillSilent` silent (no loading UI) |

## 8. Sticky Avatar

| Symbol | Behavior | Fiber mirror |
|---|---|---|
| `BufferLogContainerView.hoverUserRows` / `setStickyAuthor` | Sender's letter avatar pins to top of viewport as you scroll; direct DOM `css({top})` write (jQuery synchronous, no framework reactivity) | `MessageList.svelte:945-1101` `updateStickyAvatar` — direct `stickyAvatarEl.style.top` write |
| Transition | `transition: top 30ms linear` (Fiber addition to mask micro-jitter; IRCCloud has `transition: all 0s` but 60fps scroll events make it smooth without) | `MessageList.svelte:1229` `transition: top 30ms linear` — verified in Step 1.6 whether to keep or drop to `none` |

## 9. Performance Hints

| Hint | IRCCloud | Fiber mirror |
|---|---|---|
| `requestAnimationFrame` | Used for `fetched()` divider snap + `scrollTo` animate | `MessageList.svelte:417-425` `requestAnimationFrame(step)` in `animateScrollTo` |
| `ResizeObserver` | Observe `.messages` for height changes (typing indicator, image decode) | `MessageList.svelte:570-590` |
| Passive scroll listeners | `passive:true` + `batchRendering` flag | `MessageList.svelte:732` |
| `getBoundingClientRect` | Single `rect` per frame cached, passed to helpers (not per-row) | `MessageList.svelte:826-833` `updateScrollState` takes one `rect` |
| `elementsFromPoint` | O(1) hit test for top/bottom row (not O(n) per-row loop) | `MessageList.svelte:800-818` `rowFromPoint`/`probeRow` |

## Appendix — Capture Evidence

- `curl -sL https://www.irccloud.com/` → Cloudflare challenge page (`Just a moment...`, `cf-ray:` header) — direct bundle fetch blocked. `curl -sI https://www.irccloud.com/chat/` → `404` with `x-irccloud-sid: 7` (API-gated, not static).
- `IRCCLOUD_VISUAL_DESIGN_AUDIT.md:3` confirms bundle hash `common-ba9dfbf7.js` (2.3 MB) + 6052 CSS rules.
- `frontend/src/components/MessageList.svelte` contains 40+ inline citations to `bufferscrollview.js`/`bufferlogview.js` line-level behavior (e.g., `:743`, `:746`, `:784`, `:388`). These are the primary source for this contract per the contingency.
- `local://irccloud-capture/` — capture dir created at `/tmp/irccloud-capture/` with `landing.html`/`chat-shell.html` stubs (Cloudflare challenge HTML, not bundle). Full re-capture requires a Cloudflare-bypassing browser session (`app.relay` with existing login cookies) — recorded hashes/URLs here for re-capture: `https://www.irccloud.com/chat/` shell, `https://www.irccloud.com/common-ba9dfbf7.js` (hash may rotate), `webpack://app/src/view/bufferscrollview.js`, `webpack://app/src/view/bufferlogview.js`.

## Unverified — Confirm First

- Exact `BufferScrollView.scrollTo` duration: Fiber uses 100ms swing (matches jQuery default). If bundle shows 200ms, update `MessageList.svelte:416`.
- Whether IRCCloud's sticky avatar has `transition: none` vs `30ms linear` — to be measured in Step 1.6 (plan says pick whichever IRCCloud uses).
- `content-visibility` — no evidence IRCCloud uses it on chat rows; assumed absent (Fiber correctly scopes to `.row.bot` only).
