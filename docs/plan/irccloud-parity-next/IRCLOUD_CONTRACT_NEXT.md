# IRCCloud Parity — Next Contracts (live capture 2026-08-10)

Captured via Kimi WebBridge authenticated as `kevindpostal@gmail.com` at `2026-08-10T02:06:29Z`.
Bundles on disk `/tmp/irccloud-capture/` — hashes in `bundle-hashes.txt`:

```
https://www.irccloud.com/build/vendor-39a478db.css
https://www.irccloud.com/build/common-002a6024.css  (780217 bytes, 6118 rules)
https://www.irccloud.com/build/app-60d22d79.css
https://www.irccloud.com/build/runtime-0da33378.js
https://www.irccloud.com/build/vendor-6aab7835.js
https://www.irccloud.com/build/libs-90beb021.js
https://www.irccloud.com/build/common-5650bddb.js   (1256070 bytes)
https://www.irccloud.com/build/app-813676c8.js
```

All offsets are **character offsets from byte 0 of the single-line `webpackJsonp` file** or **byte offset inside minified `chat.css` (line 4)** unless noted as `chat-shell.html` DOM line. Use `grep -a -n` (common.js) or `grep -n` (chat.css line 4) to re-verify. Marked `unverified — confirm first` where symbol not found in captured bundle but cited in audit fallback.

---

## 1. Scroll / trim / debounce (confirm Phase 0 invariants still hold)

| Symbol | File | Offset | Verbatim | Notes |
|---|---|---|---|---|
| `trimDetectThreshold` | `common.js` | `641852` | `trimDetectThreshold:350` | `bufferMessage` guards `messageBuffer.length>this.trimDetectThreshold && slice(-trimThreshold)` |
| `trimThreshold` | `common.js` | `641924` | `trimThreshold:200` | paired with above; `BATCH_SIZE 200` invariant |
| `bufferFlushTimeout` | `common.js` | `641986` | `bufferFlushTimeout:200` | `checkFlush` debounce |
| `isScrolledToBottom` | `common.js` | `518757` / `1032683` | `isScrolledToBottom()` + `scrollTo` slop `scrollHeight - (offsetHeight+scrollTop) <=1` | 1px slop confirmed |
| `duration:100` | `common.js` | `1032683` | `$(this.el).animate({scrollTop:e},{duration:100,complete:…}` | swing 100ms — matches `frontend/src/lib/scroll.ts` |
| `getBacklogDivider` | `common.js` | `642xxx` | `getBacklogDivider:function(){return this.$(".backlogDivider")}` | backlog boundary marker |

Grep:
```bash
grep -a -o -n "trimDetectThreshold" /tmp/irccloud-capture/common.js
grep -a -n "duration:100" /tmp/irccloud-capture/common.js | head
```

---

## 2. Row states — pending / pendingOut / failed / backlog dividers

| Symbol | File | Offset | Verbatim |
|---|---|---|---|
| `renderFetchFailedDivider` | `common.js` | `114257` | `renderFetchFailedDivider:function(e){var t=["fetch","fetchFailed"];…contents:"Fetching failed"` |
| `backlogDivider` | `common.js` | `114137` | `renderBacklogDivider:function(e,t){…t.push("backlogDivider")` |
| `pendingOut` | `common.js` | `783438` | `a.addClass("pendingOut"),setTimeout(_.bind(function(){a.remove(),r.resolve()},this),200)` — 200ms dim then remove |
| `div.log div.row.pending` | `chat.css` | `37462` (line 4) | `body.theme-dusk div.log div.row.pending .bufferLink,body.theme-dusk div.log div.row.pending a{color:#6199d1}` |
| `div.log div.backlogDivider hr` | `chat.css` | `71044` | `body.theme-dusk div.log div.backlogDivider hr,body.theme-dusk div.log div.fetch hr{border-color:#4d8ccb}` |
| `div.log div.fetch span` | `chat.css` | `71090` | `padding:0 10px;background-color:#11263b;color:#4d8ccb` |
| `div.log div.fetchFailed` | `chat.css` | `699478` | `div.log div.fetchFailed,div.log div.initialFetch{padding-top:0}` + `div.log div.backlogDivider hr{border-color:#1e72ff}` (light theme) |

CSS captures dusk `#4d8ccb` vs light `#1e72ff`. Fiber's `_rowStates.scss` maps to `--row-*` vars.

---

## 3. Member prefix + mode colors + glyph

| Symbol | File | Offset | Verbatim |
|---|---|---|---|
| `getDummyUserFromModeSymbol` | `common.js` | `119591` | `this.formatter.getDummyUserFromModeSymbol(t)` → `mode_prefix mode_symbol` + `mode_pill •` |
| `mode_prefix` | `common.js` | `119744` | `class="mode_prefix mode_symbol` + `class="mode_prefix mode_pill` |
| `mode_OWNER / mode_OP / mode_VOICE` etc. | `chat.css` | `~37000-38000` | `body.theme-dusk div.log div.row.pending` block also defines mode colors; check `chat.css` search for `.mode_OP` — audit cites `color:#32cd32/#ff6347` for OP/VOICE vs OWNER; dusk verde `color:#6199d1` for pending links |
| `CATEGORY_SYMBOLS` | `common.js` | `~119600` | `~ ! & @ % + •` mapping via `getModeSymbol()` — matches Fiber `MemberList.svelte CATEGORY_SYMBOLS` |

**IRCCloud theme colors (dusk):** pending link `#6199d1`, dateChange `#17334f`/`#d7e6f4` (see below). Mode prefix colors live in `chat.css` near `mode_prefix` — search `mode_` in css.

---

## 4. Hover toolbar — `.messageActions`

| Symbol | File | Offset | Verbatim | Status |
|---|---|---|---|---|
| `.row .messageActions` | `chat.css` | `92263` | `body.theme-dusk .row .messageActions{background-color:#1d4063;color:#9cbfe2;border-color:#11263b #0b1a28 #0b1a28 #11263b}` | **verified** |
| `.messageActions__action` | `chat.css` | `92384` | `body.theme-dusk .row .messageActions__action{border-left-color:#0b1a28}` + `:hover{color:#fff}` | verified |
| `messageActions` JS builder | `common.js` | `120344` | `o+='<span class="messageActions">' … isReactable/isEditable/isDeletable` | verified — absolutely positioned toolbar hidden until `:hover`, `top:-28px right:30px` per audit fallback `irccloud_chat_css_categorized.json:21214` — **exact px not found in minified css** (minified uses `.row .messageActions` without top/right in this slice) → mark **unverified — confirm first** for pixel values, but selector is verified. |

Fiber's `MessageRow.svelte` should mirror as `.rowActions` absolute, `right:4px top:-4px`, hidden `opacity:0` → `opacity:1` on `:hover`.

---

## 5. Date header — `.dateChange` / `dateWrapper`

| Symbol | File | Offset | Verbatim |
|---|---|---|---|
| `buildDateRow` | `common.js` | `126091` | `buildDateRow:function(e,t,i){…t.push("dateChange"),this.buildRow(e,{classNames:t,contents:"<h3>"+…` |
| `div.log div.dateChange h3` | `chat.css` | `71284` | `body.theme-dusk div.log div.dateChange h3{color:#d7e6f4;background-color:#17334f}` + `box-shadow:inset 0 -3px 0 #224d77,inset 0 -4px 0 #11263b,0 -1px 0 #11263b}` |
| `div.dateWrapper table.date` | `chat.css` | `71284` | same block `body.theme-dusk div.dateWrapper table.date,body.theme-dusk div.log div.dateChange h3{color:#d7e6f4;background-color:#17334f}` |
| `linear-gradient` | `chat.css` | search `gradient` near dateChange | **unverified — confirm first** — minified dusk uses flat `#17334f` with inset box-shadow, not `linear-gradient(#fafafa,#e8e8e8)`; that gradient is light-theme. Keep `audit #4` gradient as fallback but cite as unverified for dusk. |

---

## 6. Empty channel hint — `.log:empty`

| Symbol | File | Offset | Verbatim | Status |
|---|---|---|---|---|
| `This is the beginning of #` | `chat-shell.html` / `common.js` | — | Not found via `grep -n "This is the beginning"` in captured `chat-shell.html` or `common.js` | **unverified — confirm first** — audit cites `chat-shell.html .log:empty` text; captured `chat-shell.html` (508K) does not contain literal in this slice. Fiber's `MessageList.svelte` empty hint `#{stripHash(bufferName)} / No messages yet` is intentional parity, not verbatim copy. |

---

## 7. Connection status pill — `.connectionStatus`

| Symbol | File | Offset | Verbatim |
|---|---|---|---|
| `.connectionStatus` | `chat.css` | `32094` | `body.theme-dusk .connectionStatus{border-color:#224d77;background-color:#224d77;color:#c4d9ee}` |
| `.connectionStatus.reconnect a` | `chat.css` | `32094-32289` | `body.theme-dusk .connectionStatus.disconnect a,body.theme-dusk .connectionStatus.edit a,body.theme-dusk .connectionStatus.reconnect a,body.theme-dusk .connectionStatus.upgrade a{border-color:#224d77;background-color:#1d4063;color:#c4d9ee}` |
| `.connectionStatus.away a` | `chat.css` | `32094` | `body.theme-dusk .connectionStatus.away a{border-color:#1d4063;background-color:#17334f;color:#88b3dd}` |
| `connectionstatuscell` | `chat-shell.html` | `734` | `<div class="connectionstatuscell"><div class="connectionStatus"></div></div>` + `2707` second cell |

Fiber's `ConnectionStatus.svelte` calm minimal-mono redesign maps these to left-edge hairlines (`border-left-color: var(--fiber-blue)/--fiber-amber`) rather than tinted pill — same token values `#1d4063/#224d77/#c4d9ee` but applied as edge not background. Legacy pill rules removed in `_statusCells.scss` with comment.

---

## 8. Typing indicator

| Symbol | File | Offset | Verbatim | Status |
|---|---|---|---|---|
| `.typing-dots` / `typing-bounce` | `chat.css` | not found at `typing` lowercase search in `chat.css` | **unverified — confirm first** — audit cites `chat.css` `typing-dots i {width:4px; animation:typing-bounce 1.2s}` with `nth-child` delays, but minified `chat.css` (line 4) has no `typing` literal in this capture. `common.js` also has no `typing-bounce` in this slice. | Fiber implements via `_chatInput.scss` from audit fallback `irccloud_chat_css_categorized.json` — 1.2s bounce with 0.15s/0.3s delays + `prefers-reduced-motion`. |
| `Share typing status` | `chat-shell.html` | `603` / `1215` | `<th><label for="prefsTypingStatus">Share typing status` + context menu `typing` | verified — feature is `TAGMSG @+typing=active` (see `InputArea.svelte` `sendTypingActive` every ~3s). |

---

## 9. Theme vars — `body.theme-dusk / midnight`

| Symbol | File | Offset | Verbatim |
|---|---|---|---|
| `body.theme-dusk` | `chat.css` | `26767` | `body.theme-dusk{color:#c4d9ee;background-color:#11263b` + 190+ properties |
| `body.theme-midnight` | `chat.css` | `494909` | `body.theme-midnight{color:#d9d9d9;background-color:#000` |
| `body.theme-ash` | `chat.css` | `4947xx` | sibling `body.theme-ash{…}` |
| `themes/` in Fiber | — | — | `frontend/src/styles/themes/_dusk.scss` etc. mirror tokens; Fiber uses `var(--fiber-*)` not IRCCloud hex directly. |

Count via `grep -o "body.theme-" /tmp/irccloud-capture/chat.css | wc -l` ≈ 190 properties (audit count).

---

## How to re-capture if bundles rotate

```bash
# hashes
cat /tmp/irccloud-capture/bundle-hashes.txt  # 8 URLs
# if common-*.js hash changes (e.g. 5650bddb → new), re-capture via WebBridge:
curl -s -X POST http://127.0.0.1:10086/command \
  -d '{"action":"network","args":{"cmd":"list"}}' | python3 -m json.tool | grep common
curl -s -X POST http://127.0.0.1:10086/command \
  -d '{"action":"network","args":{"cmd":"detail","id":"<requestId>"}}' > /tmp/new-common.js
# then re-run grep -a -o -n above and update this file; mark any new symbol as unverified if not found
```

No Fiber edits in Phase 0 — this file is the source of truth for Phase 1.
