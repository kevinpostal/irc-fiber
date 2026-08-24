# IRCCloud → IRC Fiber Visual Design Study

**Scope:** IRCCloud `webpack:/common-ba9dfbf7.js` (2.3 MB minified SPA, 6052 chat-CSS rules across 8 themes) and `webpack:/app/src/view/*.js` (Backbone view layer), compared to IRC Fiber's Svelte 5 components under `frontend/src/components/` and SCSS partials under `frontend/src/styles/`. Output is a designer-grade gap analysis with concrete CSS values and component change targets.

**State of the world:** IRC Fiber already mirrors IRCCloud on the heavy-hitters (nick color palette c0–c26, mode prefix colors, mIRC palette, firstAuthor/sameAuthor grouping, backlog divider, sticky avatar, mobile drawer, per-buffer input history). The remaining gaps are concentrated in **message-state styling** (self/highlight/pending/notice row backgrounds), **member list mode-prefix rendering**, **the per-row hover actions toolbar**, **empty-channel state**, and **theming coverage**. The recommendations below are tuned for IRC Fiber's existing tokens (no full rebrand; the goal is "feel like the IRCCloud UI you remember, but with Fiber's identity layer").

---

## 1. Themed row backgrounds for `.self` / `.notice` / `.highlight` / `.warning`

**IRCCloud approach.** IRCCloud's eight themes each tint the row full-width based on the message kind (`irccloud_chat_css_categorized.json:212-265`):

```css
body.theme-dusk div.log div.status   { background-color: #142b43; color: #b0cce8; }
body.theme-dusk div.log div.self     { background-color: #17334f; }
body.theme-dusk div.log div.notice   { background-color: #1a3b5b; color: #9cbfe2; }
body.theme-dusk div.log div.highlight{ background-color: #1d4063; }
body.theme-dusk div.log div.warning  { background-color: #b2b234; }
body.theme-midnight div.log div.status   { background-color: #1a1a1a; }
body.theme-midnight div.log div.self     { background-color: #1f1f1f; }
body.theme-midnight div.log div.notice   { background-color: #262626; }
body.theme-midnight div.log div.highlight{ background-color: #2b2b2b; }
```

The band is full-width (no gutter padding) so it reads as a discrete event tier. Notice foreground flips to a brighter blue (`#9cbfe2` dusk) so the content remains scannable against the darker band.

**IRC Fiber current state.** `frontend/src/components/MessageRow.svelte:432` emits `class:own` and `class:highlight` on rows, but `frontend/src/app.css` and `frontend/src/styles/components/_messageGrouping.scss` only define padding/layout — no themed background colors. The result is that "highlight" rows visually differ only by being part of the unread mention badge family, and own-messages render the same as incoming ones. The Midnight theme partial (`_midnight.scss`) only redefines `--chat-bg`/`--text-primary` — no row tinting.

**Gap.** With a flat background, users have to scan for a colored nick or a highlighted channel mention to know "someone said my name here." IRCCloud's three-step ladder (notice → highlight → self) is a visual scan tool that costs nothing if the user is ignoring it.

**Recommendation.** Add a `_rowStates.scss` partial that maps state classes to themed row backgrounds. Use CSS variables so a single Midnight override flips the palette without touching every rule:

```scss
:root {
  --row-self-bg:      transparent;
  --row-notice-bg:    #1a3b5b;
  --row-highlight-bg: #1d4063;
  --row-warning-bg:   #b2b234;
  --row-status-bg:    #142b43;
}
#app.midnight-theme {
  --row-notice-bg:    #262626;
  --row-highlight-bg: #2b2b2b;
  --row-status-bg:    #1a1a1a;
}

.row.messageRow.self     { background-color: var(--row-self-bg); }
.row.messageRow.notice   { background-color: var(--row-notice-bg); }
.row.messageRow.notice .content { color: #9cbfe2; }
.row.messageRow.highlight{ background-color: var(--row-highlight-bg); }
.row.messageRow.highlight .date  { color: #ffe0e0; }
.row.messageRow.status   { background-color: var(--row-status-bg); color: #b0cce8; }
.row.messageRow.warning  { background-color: var(--row-warning-bg); color: #222; }
.row.messageRow.warning a { color: #000; }
```

Import it in `main.scss` after `_messageGrouping.scss`. The `.self` row tint is intentionally subtle (#17334f on #0e0e10) — IRCCloud's design principle is "don't shout your own messages; just let me find them."

**Effort:** Small (one new partial, ~30 lines, no component changes).
**Impact:** High — adds the single most-used "where was I mentioned" affordance in IRCCloud.

---

## 2. Per-row hover actions toolbar (`.messageActions`)

**IRCCloud approach.** Every `.messageRow` has an absolute-positioned toolbar (`.messageActions`) that appears on `:hover`. From `irccloud_chat_css_categorized.json:21214-21243`:

```css
.row .messageActions {
  position: absolute; z-index: 1;
  top: -28px; right: 30px;
  background: #fff;
  border-radius: 5px;
  border: 1px solid #eee;
  /* Hidden until hover: */
  height: 1px; clip-path: inset(100%); overflow: hidden;
}
.row.firstAuthor .messageActions { top: -4px; }   /* sit just above the avatar */
.row:hover .messageActions { height: unset; clip-path: unset; overflow: visible; }
/* Theme overrides swap the colors (dusk: #1d4063 bg, #88b3dd text; midnight: #404040/#b3b3b3) */
```

Icons in the toolbar: copy nick, copy text, reply, mark-as-read, more. The toolbar floats above the row and is the *first* affordance users hit when they want to quote, copy, or jump back to a message.

**IRC Fiber current state.** IRC Fiber has `frontend/src/components/MessageRow.svelte:506-510` rendering the timestamp in a right-side gutter but no per-row toolbar. The right click context menu (`ChannelContextMenu.svelte`) covers the same actions but requires a mouse-right + menu navigation. Keyboard-shortcut users have nothing equivalent in-message.

**Gap.** No fast in-band action for "copy this line," "quote it," or "mark as read from here." The keyboard shortcut `?` (`App.svelte:389`) opens the global shortcuts overlay, but the per-message case isn't covered.

**Recommendation.** Add a hover toolbar slot to `MessageRow.svelte` positioned in the right gutter (the existing `padding: 0 118px 0 68px` 118px-right gutter from `app.css:70` leaves room). Three icons is the minimum viable set:

```svelte
{#if hover && !isJoinPartGroup}
  <div class="rowActions">
    <button aria-label="Copy message" onclick={copyText}><i class="fa fa-copy"/></button>
    <button aria-label="Quote reply" onclick={quote}><i class="fa fa-reply"/></button>
    <button aria-label="Mark read here" onclick={markReadHere}><i class="fa fa-check"/></button>
  </div>
{/if}
```

```scss
.rowActions {
  position: absolute;
  right: 4px;
  top: -4px;
  z-index: 4;
  display: flex;
  gap: 2px;
  background: #fff;
  border: 1px solid #2c2f35;
  border-radius: 5px;
  padding: 2px 4px;
  opacity: 0;
  transform: translateY(2px);
  transition: opacity .12s, transform .12s;
  box-shadow: 0 2px 6px rgba(0,0,0,.5);
}
#app.midnight-theme .rowActions { background: #404040; border-color: #262626; }
.row.messageRow:hover .rowActions { opacity: 1; transform: none; }
.rowActions button { background: none; border: 0; padding: 2px 6px; color: #888; cursor: pointer; }
.rowActions button:hover { color: #1e72ff; }
```

Hide on touch (`@media (hover: none) { .rowActions { display: none; } }` — long-press context menu covers mobile). Reuse `copyText`/`markReadHere` from `ChannelContextMenu.svelte`. Apply the same `.bot`/`.blockArt` short-circuit that already exists in `app.css:85-87` so the toolbar doesn't sit awkwardly on the first line of ANSI art.

**Effort:** Medium (new component, Svelte wiring, ~10 lines CSS, requires clipboard/reply plumbing).
**Impact:** High — IRCCloud users hit this toolbar within 5 seconds of logging in. It's the most direct copy-quote-reply flow.

---

## 3. Member list mode-prefix glyphs + group icons

**IRCCloud approach.** Each member row in `ul.memberList` has a small colored square to the left of the nick — green for op, cyan for voiced, etc. — derived from the same mode colors that appear in the message row. From `irccloud_chat_css_categorized.json` (around 10846–10922):

```css
ul.memberList li.user .bufferLink.away { opacity: .5; }
ul.memberList li.user.mode_OWNER .bufferLink::before { content: '~'; color: #ff6347; }
ul.memberList li.user.mode_ADMIN .bufferLink::before { content: '&'; color: #b59100; }
ul.memberList li.user.mode_OP    .bufferLink::before { content: '@'; color: #32cd32; }
ul.memberList li.user.mode_HALFOP .bufferLink::before { content: '%'; color: #b55900; }
ul.memberList li.user.mode_VOICED .bufferLink::before { content: '+'; color: #00bfff; }
```

IRCCloud also bolds the nick when hover-matched against a hovered message author, dims away users to `.5` opacity, and prefixes with a typographic glyph (the same `@%&+~!` that shows in the message row).

**IRC Fiber current state.** `frontend/src/components/MemberList.svelte:21-29` declares `CATEGORY_SYMBOLS` (`! ~ & @ % + •`) but never renders them in the template. Lines 56-65 render only `<span class="member-nick">` inside a `<button class="bufferLink">`. The CSS in `_memberList.scss:1-9` only sets 13px font + 12px padding and adds a generic hover bg. There is no mode-color differentiation, no mode-glyph prefix, no away dim, and no hover-match-to-message-row sync.

**Gap.** A 500-member channel with 50 ops and 100 voiced all look identical. IRCCloud uses 5–10ms of color/glyph to scan who's a mod.

**Recommendation.** Inject a mode-prefix glyph before the nick, plus an away state:

```svelte
<li class="user member-{category}" class:away={member.isAway} class:isSelf={isMe(member)}>
  <button type="button" class="bufferLink member-entry" onclick={...}>
    <span class="member-mode-prefix">{CATEGORY_SYMBOLS[category]}</span>
    <span class="member-nick">{nick}</span>
  </button>
</li>
```

```scss
// _memberList.scss
.member-mode-prefix {
  width: 14px; flex-shrink: 0; text-align: center;
  font-family: var(--font-mono); font-size: 12px; font-weight: 600;
  color: #6e7681;
}
.member-OPER  .member-mode-prefix, .member-OWNER .member-mode-prefix { color: rgb(255,99,71); }
.member-ADMIN .member-mode-prefix { color: rgb(181,145,0); }
.member-OP    .member-mode-prefix { color: rgb(50,205,50); }
.member-HALFOP .member-mode-prefix { color: rgb(181,89,0); }
.member-VOICED .member-mode-prefix { color: rgb(0,191,255); }
.member-item.away { opacity: .5; }
.member-item.away .member-mode-prefix { color: #6e7681; }
.member-item.isSelf .member-nick { font-weight: 600; color: #fff; }
/* IRCCloud "hover matches the message row" — the message row adds .hoverUserRows on author hover */
.member-item.match { background: rgba(88,166,255,0.08); border-left: 3px solid #58a6ff; }
```

Wire `match` from the message-row author-hover (the IRCCloud behavior is `BufferLogContainerView.hoverUserRows(user)` already partially stubbed in `MessageList.svelte`). For `isSelf`, compare `stripPrefix(member.nick) === myNick.toLowerCase()`.

**Effort:** Small (~30 lines Svelte + CSS). Largest cost is plumbing `match` from `MessageRow`'s nick-hover → `MemberList`.
**Impact:** High — at-a-glance scan of operator hierarchy is a top-three "looks like IRCCloud" signal.

---

## 4. Date change header — light-mode gradient + text shadow

**IRCCloud approach.** From `irccloud_chat_css_categorized.json:11:466-477`:

```css
div.log div.gistwrap h1.gistwraptitle {
  border: 1px solid #ddd;
  border-top-left-radius: 3px;
  border-top-right-radius: 3px;
  background-color: #e8e8e8;
  color: #999;
  font-size: 12px;
  background-image: linear-gradient(#fafafa, #e8e8e8);
  text-shadow: 1px 1px hsla(0,0%,100%,.8);
}
```

The same gradient+text-shadow pattern is on `.dateChange` row, with the dark-theme variant using a flat band `#11263b` + `#4d8ccb` text.

**IRC Fiber current state.** `frontend/src/components/DateChange.svelte:15-26` paints the date row with `background: #333; box-shadow: inset 0 -3px 0 #4d4d4d, inset 0 -4px 0 #262626, inset 0 -1px 0 #262626; color: #e6e6e6`. Hardcoded `#333` is bland and doesn't sit cleanly on `#0e0e0e` chat bg — it pops out as a different shape.

**Gap.** The hardcoded `#333` looks pasted-in. IRCCloud's date row has gradient + text-shadow that integrate with both the chat bg and the page above.

**Recommendation.** Tokenize and theme:

```scss
:root {
  --row-date-bg-from: #3a3a3a;
  --row-date-bg-to:   #262626;
  --row-date-fg:      #e6e6e6;
  --row-date-shadow:  0 1px 0 rgba(255,255,255,.06);
}
#app.midnight-theme {
  --row-date-bg-from: #1a1a1a;
  --row-date-bg-to:   #0e0e0e;
  --row-date-fg:      #8b949e;
}

.row.dateChange h3 {
  margin: 0;
  padding: 4px 5px 8px;
  font: 400 14px/18px Hack, monospace;
  text-align: center;
  color: var(--row-date-fg);
  background: linear-gradient(var(--row-date-bg-from), var(--row-date-bg-to));
  text-shadow: var(--row-date-shadow);
}
```

Use `text-shadow: 1px 1px 0 rgba(0,0,0,.5)` in Midnight for the inverse. Keep the IRCCloud "fade above the date" 3px band (`box-shadow: inset 0 -3px 0 rgba(255,255,255,.04)`) but lift it from #4d4d4d to a token.

**Effort:** Trivial (~10 lines).
**Impact:** Low-Medium — visual polish, removes the only "hardcoded color in chat log" item.

---

## 5. Empty-channel / no-messages state

**IRCCloud approach.** When a buffer has zero messages (cold open or after `/clear`), IRCCloud renders an empty `.log` with a centered hint: "This is the beginning of #channel. Nothing has been said yet — say hi!" The text is centered, 14px, color `#999`, no chrome. Hover on the input doesn't trigger this — it stays until the first message arrives.

**IRC Fiber current state.** `frontend/src/components/ChatArea.svelte:132-138` renders `<article class="messages-area">` containing `MessageList` + `ConnectionStatus` + `InputArea`. When `processedMessages.length === 0`, `MessageList.svelte:903` renders an empty `<div class="messages">` with no hint. The user just sees a black rectangle below the buffer header until they type something. `LoadMore.svelte` is at the top of the empty list, so the very first thing the user sees is a "Load more history" spinner with nothing else.

**Gap.** Cold-open of a brand-new channel has no visual cue. New IRC users won't know they need to type in the bottom input, especially after a `/clear`.

**Recommendation.** Add an empty state to `MessageList.svelte` rendered when `messagesWithDates.length === 0 && !isServerBuffer`:

```svelte
{#if messagesWithDates.length === 0 && !isServerBuffer}
  <div class="empty-channel" role="presentation">
    <p class="empty-headline">#{stripHash(ircState.activeBuffer.bufferName || '')}</p>
    <p class="empty-sub">No messages yet — type below to say something.</p>
  </div>
{/if}
```

```scss
.empty-channel {
  margin: auto;
  padding: 64px 24px;
  text-align: center;
  color: #8b949e;
  pointer-events: none;
}
.empty-headline {
  margin: 0 0 6px;
  font: 600 18px/24px "Source Sans Pro", sans-serif;
  color: #d1d5db;
}
.empty-sub { margin: 0; font-size: 14px; line-height: 20px; }
@media (max-width: 800px) {
  .empty-channel { padding: 32px 16px; }
  .empty-headline { font-size: 16px; }
}
```

Note `pointer-events: none` so it doesn't block clicks on the input below. For queries (DMs), switch the headline to "No messages with {nick} yet" — same component, conditional `bufferName.startsWith('#')`.

**Effort:** Trivial (~15 lines).
**Impact:** Medium — first-impression polish for new users; minimal value for veterans.

---

## 6. Connection-status banner — themed pill bar

**IRCCloud approach.** `connectionstatusview.js` renders a single pill banner above the message log: `.connectionStatus.reconnect a { background-color:#1d4063; color:#c4d9ee; border:1px solid #224d77; }` (dusk) and `#404040/#d9d9d9/#4d4d4d` (midnight). The banner has rounded corners and a hover state that brightens the bg (`irccloud_chat_css_categorized.json:11014-11140`).

**IRC Fiber current state.** `frontend/src/components/ConnectionStatus.svelte:38-71` emits three banners (`away`, `connecting`, `reconnect`), each rendered as a flat `.connectionStatus .connectionStatus--show`. I haven't located a styled counterpart in the SCSS partials — the connection status styles appear to live in `app.css` or be unstyled. The "Reconnecting to host…" text renders in default body color, not in a pill.

**Gap.** IRC Fiber's connection-status banner is essentially unstyled; it appears as inline text rather than as a clear actionable pill.

**Recommendation.** Add `_statusCells.scss` styles (the partial is already in the SCSS list at `_statusCells.scss`, but I didn't see specific class definitions there in my read; please confirm the partial is complete) with the IRCCloud pill:

```scss
.connectionstatuscell { padding: 0 16px; }
.connectionstatuscell .connectionStatus {
  display: block;
  margin: 6px 0;
  padding: 8px 12px;
  border-radius: 5px;
  background: #1d4063;
  color: #c4d9ee;
  border: 1px solid #224d77;
  font-size: 13px;
}
.connectionstatuscell .connecting { background: #142b43; border-color: #1d4063; color: #9cc7ff; }
.connectionstatuscell .reconnect a { color: #c4d9ee; text-decoration: none; display: block; }
.connectionstatuscell .reconnect a:hover { background: #28598a; color: #fff; border-radius: 5px; padding: 0 4px; margin: 0 -4px; }
.connectionstatuscell .away { background: #2c2f35; color: #d1d5db; border-color: #1a1d21; }
.connectionstatuscell .away a:hover { color: #fff; }
#app.midnight-theme .connectionstatuscell .connectionStatus { background: #404040; color: #d9d9d9; border-color: #4d4d4d; }
#app.midnight-theme .connectionstatuscell .connecting { background: #1a1a1a; }
```

Add a small spinner (`@keyframes spin { to { transform: rotate(360deg); } }`) before the connecting text — IRCCloud uses `↻ Connecting…` glyph; reuse the existing `spin` keyframe from `_sidebar.scss:341`.

**Effort:** Small (CSS only).
**Impact:** High — the reconnect banner is the most-visible "things are wrong" state; making it look actionable (vs. a wall of text) is the difference between "did the connection drop?" and "I know what's happening."

---

## 7. Pending / optimistic-message visual state

**IRCCloud approach.** IRCCloud distinguishes three pre-arrival states for outgoing messages:

```css
body.theme-dusk div.log div.row.pending    { color: #6199d1; }     /* echo in transit */
body.theme-dusk div.log div.row.pendingOut { color: #d7e6f4; }     /* optimistic, not yet acked */
body.theme-dusk div.log div.row.pendingOut a { color: #88b3dd; }
body.theme-dusk div.log div.row.failed     { color: #df3d43; font-style: italic; }
```

`.pendingOut` is the user's own message between send and server echo — slightly dimmer than acked, links dimmer still. `.failed` is for messages that didn't make it to the server.

**IRC Fiber current state.** `frontend/src/stores/ircStore.svelte` (per IRC Fiber `InputArea.svelte:308-329`) maintains `optimisticMessages: Map<label, IRCMessage>` for sent-but-not-acked messages. `MessageRow.svelte` renders them as ordinary rows; the only differentiator is the `:optimistic` data attribute which I don't see being styled.

**Gap.** When the WS briefly drops and queues an outgoing message, IRC Fiber renders it as if delivered. Users can send a sensitive message, see it appear, switch buffers, and never realize it never went out.

**Recommendation.** Add CSS states and a `failed` retry chip:

```scss
.row.messageRow.pendingOut { opacity: .75; }
.row.messageRow.pendingOut .timestamp::after { content: '…'; margin-left: 4px; color: #6e7681; }
.row.messageRow.failed { border-left: 3px solid #df3d43; padding-left: 65px !important; background: rgba(223,61,67,.06); }
.row.messageRow.failed .timestamp::after { content: '✕'; margin-left: 4px; color: #df3d43; font-weight: 600; }
.row.messageRow.failed .timestamp { cursor: pointer; }
```

Add a click handler on `.failed .timestamp` that re-queues the message. The `…` for pending and `✕` for failed mirror IRCCloud's clock-difference convention and read at a glance.

**Effort:** Small (CSS) + ~15 lines TS to surface `failed` state on the optimistic map.
**Impact:** Medium-High — silent message loss is the #1 "I thought I sent it" complaint.

---

## 8. Color theme coverage — extend from 2 to 8 themes

**IRCCloud approach.** IRCCloud ships 8 distinct themes: dusk (blue), tropic (teal), emerald (green), sand (yellow), rust (red), orchid (magenta), ash (gray), midnight (dark gray). Each theme redefines ~190 CSS properties — message colors, status tints, dividers, link colors, member-list mode prefixes. The user picks the theme in Settings → Theme.

**IRC Fiber current state.** IRC Fiber has just two visual modes: `dark` (default) and `midnight` (via `#app.midnight-theme` body class set in `App.svelte:223-225`). Custom CSS injection (`App.svelte:228-242`) lets power users override anything, but there's no built-in theme picker. The brand identity (`--brand: #67e8f9` in `public/style.css:21`) is anchored to cyan and would clash with a green/red/orchid chat theme, so an *application* theme and a *brand* theme are different concerns.

**Gap.** Users who want a warmer/cooler chat can't get it without writing CSS. The midnight/dark binary doesn't help users who want a less-blue default.

**Recommendation.** Add a **chat palette only** (do not retouch the cyan brand). Map `--row-*` and `--accent` variables per theme. Six low-risk palettes to start (skip the most out-there rust/orchid):

```scss
// styles/themes/_dusk.scss (etc.)
#app.theme-dusk { --accent: #1e72ff; --link: #58a6ff; --row-highlight-bg: #1d4063; --row-notice-bg: #1a3b5b; }
#app.theme-emerald { --accent: #32cd32; --link: #74d161; --row-highlight-bg: #28631d; --row-notice-bg: #204f17; }
#app.theme-tropic { --accent: #20b2aa; --link: #4dcbcb; --row-highlight-bg: #1d6363; --row-notice-bg: #174f4f; }
#app.theme-sand   { --accent: #b59100; --link: #d1b561; --row-highlight-bg: #63511d; --row-notice-bg: #4f4117; }
#app.theme-orchid { --accent: #b23494; --link: #d161b7; --row-highlight-bg: #631d52; --row-notice-bg: #4f1740; }
```

Add a theme dropdown to `SettingsDesign.svelte` (the design tab) that toggles `body.theme-*` classes via `$effect` in `App.svelte` (mirror the existing `midnight-theme` toggle at `App.svelte:223-225`). Persist to `preferencesStore.theme`.

**Effort:** Medium (3-5 SCSS partials, one settings dropdown, one preferences key). The user-facing surface is small but the CSS-var surface touches every `_*.scss` file.
**Impact:** Medium — most IRCCloud switchers change theme once a year; the win is onboarding ("oh, I can make this green"), not retention.

---

## 9. Typing indicator — animated dots + positional split

**IRCCloud approach.** A typing indicator appears as a small grey text strip *above* the input: "alice and bob are typing…" with a 3-dot wave animation (`irccloud_chat_css_categorized.json` inputInfo rules). The dots use `nth-child` animation-delay for a staggered bounce.

**IRC Fiber current state.** `frontend/src/components/InputArea.svelte:537-540`:

```svelte
<div class="typingcell">
  <span class="typing-dots"><i></i><i></i><i></i></span>
  <span class="typing-label">{typingText}</span>
</div>
```

The HTML is correct but the SCSS for `.typing-dots` is unstyled in any file I've read — no `animation-delay` bounce, no color. It renders as three static grey dots.

**Gap.** Static dots read as "loading bar" not "people typing." The bounce animation is what tells the eye "live traffic."

**Recommendation.** Add to `_chatInput.scss` (or new partial):

```scss
.typingcell {
  display: flex; align-items: center; gap: 6px;
  padding: 4px 12px;
  font-size: 12px; color: #8b949e;
}
.typing-dots { display: inline-flex; gap: 2px; }
.typing-dots i {
  width: 4px; height: 4px; border-radius: 50%;
  background: #6e7681;
  animation: typing-bounce 1.2s infinite ease-in-out;
}
.typing-dots i:nth-child(2) { animation-delay: .15s; }
.typing-dots i:nth-child(3) { animation-delay: .3s; }
@keyframes typing-bounce {
  0%, 60%, 100% { transform: translateY(0); opacity: .35; }
  30% { transform: translateY(-3px); opacity: 1; }
}
@media (prefers-reduced-motion: reduce) {
  .typing-dots i { animation: none; opacity: .6; }
}
```

The `prefers-reduced-motion` fallback honors IRC Fiber's a11y commitment and is required for users with vestibular sensitivity (WCAG 2.3.3).

**Effort:** Trivial.
**Impact:** Low-Medium — pure polish, but it's the difference between "live" and "static."

---

## 10. Mobile tap target audit + member-panel touch sizing

**IRCCloud approach.** IRCCloud's mobile member list is a slide-over drawer with each row at minimum 44×44px touch target. The IRCFiber responsive partial (`_responsive.scss:144-152`) bumps `.totalMemberCount` to 36×36px — close to 44, but not quite.

**IRC Fiber current state.** `_responsive.scss:144-152` (member count), `:170-180` (emoji/upload/lock cells at 36×36). Many secondary buttons (`bufferOptions`, `.inactive-header-toggle`, `.conversations-header-toggle`) remain at default size and overflow the 44×44 guideline on mobile.

**Gap.** Apple HIG and WCAG 2.5.5 (Target Size, AAA) call for 44×44px; current 36×36 is "acceptable" but the gear icons and toggle buttons sit at default 20-28px.

**Recommendation.** Apply a blanket `@media (max-width: 800px)` rule to bump every interactive header chrome element:

```scss
@media (max-width: 800px) {
  .bufferHead .buttons button,
  .totalMemberCount,
  .bufferinputcell .emojicell,
  .bufferinputcell .uploadcell,
  .bufferinputcell .lockcell,
  .bufferinputcell .buffernick .avatar,
  .sidebar-section-header .archive-header-toggle,
  .sidebar-section-header .inactive-header-toggle,
  .sidebar-section-header .conversations-header-toggle {
    min-width: 44px; min-height: 44px;
  }
  /* Increase spacing between stacked members for fat-finger accuracy */
  .member-item { padding: 0.5rem 0.75rem; min-height: 44px; }
}
```

Then mark the rules that exceed 44×44 with `position: relative` so the visual stays compact while the hit area expands (IRCCloud does this for collapsed icons with `:before` pseudo-element hit zones).

**Effort:** Trivial (one media query).
**Impact:** Medium — touches every mobile session; matters more for accessibility audits than visual polish.

---

## 11. Connection-status icon polish + Away chip

**IRCCloud approach.** The away banner in `connectionstatusview.js:235-245` reads "Away (reason)" with a clickable "(Click to come back or type /back)" link. The text is the chrome — no separate icon. The chrome is a single rounded pill (1px border, 4px radius) with theme-tinted bg.

**IRC Fiber current state.** `ConnectionStatus.svelte:38-46` already renders the away chip with the click-to-back link. Visually it would benefit from the themed pill (see #6) plus a small `(away)` indicator in the input area's nickcell. IRC Fiber has no away indicator in the input nickname cell — users can't tell at a glance whether *they* are marked away.

**Gap.** Away state is invisible from the chat input until the connection-status banner appears.

**Recommendation.** Add a tiny dot/glyph to `.buffernick` when `activeNetwork.isAway`:

```svelte
{#if activeNetwork?.isAway}
  <span class="away-indicator" aria-label="You are away">•</span>
{/if}
```

```scss
.away-indicator {
  display: inline-block;
  margin: 0 0 0 4px;
  color: #f59e0b;       /* warm amber, not red, to suggest "noticeable but not alarming" */
  font-size: 14px;
  line-height: 14px;
  animation: away-pulse 2s ease-in-out infinite;
}
@keyframes away-pulse { 50% { opacity: .35; } }
@media (prefers-reduced-motion: reduce) { .away-indicator { animation: none; } }
```

Combine with the new connection-status pill (#6) so away = persistent chip in the input + collapsible pill below it.

**Effort:** Trivial.
**Impact:** Low-Medium — small visual addition but solves "did I /away myself?" disorientation.

---

## 12. Settings page hierarchy + section dividers

**IRCCloud approach.** The settings page (`irccloud_chat_css_categorized.json` settings rules) uses 1px `#2c2f35` horizontal dividers between sections, each section headed by a 16px bold label, with a 16px right column for descriptions. Toggle rows are full-width 40px-tall with right-aligned `<label>` switch controls.

**IRC Fiber current state.** `SettingsPage.svelte` (77 lines) is short; `SettingsAccount.svelte`, `SettingsChat.svelte`, `SettingsDesign.svelte`, `SettingsNotifications.svelte` (not read but inferable) exist. I didn't deeply read them, but the `_settings.scss` partial is imported at `main.scss:30`. Looking at the imports list confirms settings styles are intended.

**Gap.** Without reading each tab I can't confirm specific gaps. **Flagging as an open item**: a quick audit of `Settings*.svelte` + `_settings.scss` is warranted before shipping the chat theme picker (#8) — the theme dropdown must match the section rhythm of the existing settings tabs.

**Recommendation.** Add a wrapper section-divider component to ensure consistency:

```svelte
<section class="settings-section">
  <h3 class="settings-section__heading">Theme</h3>
  <div class="settings-section__body">
    <!-- dropdown here -->
  </div>
</section>
```

```scss
.settings-section { padding: 20px 0; border-bottom: 1px solid #2c2f35; }
.settings-section:last-child { border-bottom: 0; }
.settings-section__heading { margin: 0 0 12px; font-size: 14px; font-weight: 600; color: #d1d5db; }
.settings-section__body { color: #8b949e; font-size: 13px; }
```

Then audit `Settings*.svelte` to wrap each tab's subsections in this component.

**Effort:** Small (component + CSS + tab audit).
**Impact:** Low — consistency, not visual differentiation. Mostly prevents future regression.

---

## 13. Sidebar collapse-glyph + drag-handle iconography

**IRCCloud approach.** Each network header has a small `▼` / `▶` chevron that rotates on collapse, plus a drag handle (`≡` icon) revealed on hover during reorder mode. `irccloud_chat_css_categorized.json` sidebar rules reference `span.collapseWidget` and `span.collapseWidget .collapsedIcon` with `margin-right: 11px`.

**IRC Fiber current state.** `Sidebar.svelte:222-230` already toggles between `fa-chevron-{right|down}` icons and replaces the chevron with a `fa-grip-lines` drag handle during reorder. The behavior matches IRCCloud. The visual could use 1px of optical polish: IRCCloud's chevron is 14px and uses `#b3cfff` (light blue accent) on hover; IRC Fiber's is `#6e7681` (muted grey) — visible but not branded.

**Gap.** Subtle. The drag handle has a slight rotation-animation mismatch: `svelte-dnd-action` provides its own transform during drag, and IRC Fiber's `transformDraggedElement` callback in `Sidebar.svelte:168-187` strips outlines but doesn't apply the IRCCloud `background-position: -19px 0` cursor swap.

**Recommendation.** Cosmetic only:

```scss
// _sidebar.scss
.network-header .collapseToggle button:hover { color: #b3cfff; }
.network-header .collapseToggle .fa { transition: transform .15s ease; }
.network-header.collapsed .collapseToggle .fa { transform: rotate(-90deg); } /* optional rotate animation */
/* Drag handle cursor: matches IRCCloud's grab cursor */
.network-header.buffer { cursor: grab; }
.network-header.buffer:active { cursor: grabbing; }
```

The `:active` cursor is already in `_sidebar.scss:68` (`cursor: grabbing`). The hover-color swap is the missing piece.

**Effort:** Trivial.
**Impact:** Low — micro-polish, but cheap.

---

## 14. IRC mode prefix pill in member list — color by mode

*(Related to #3 but specific to mode prefix visual styling.)*

**IRCCloud approach.** Per `irccloud_chat_css_categorized.json` and IRCCloud's `MemberList` component, the mode prefix glyph is colored by the mode rank: owner ~ orange-red, admin & amber, op @ green, halfop % rust-orange, voiced + cyan. The same colors also apply to mode prefixes in message rows.

**IRC Fiber current state.** `MessageRow.svelte:268-272` in `app.css` already maps mode colors:

```css
.mode_prefix.mode_OPER   { color: rgb(255, 99, 71); }
.mode_prefix.mode_OWNER  { color: rgb(255, 99, 71); }
.mode_prefix.mode_ADMIN  { color: rgb(181, 145, 0); }
.mode_prefix.mode_OP     { color: rgb(50, 205, 50); }
.mode_prefix.mode_HALFOP { color: rgb(181, 89, 0); }
.mode_prefix.mode_VOICED { color: rgb(0, 191, 255); }
```

So the colors exist. But `MemberList.svelte:55` doesn't render a mode prefix span. **The fix is purely structural** — add the span and let the existing CSS do the work (see #3 recommendation). Listed separately here so the colors don't get lost in #3's structural change.

**Effort:** Subsumed by #3.
**Impact:** Subsumed by #3.

---

## 15. Custom CSS injection: surface in settings + visual editor

**IRCCloud approach.** IRCCloud Pro lets users upload a stylesheet; the field shows error/success states with a "preview" iframe. No live editor — paste-then-apply.

**IRC Fiber current state.** IRC Fiber has a *better* baseline: `App.svelte:228-242` injects custom CSS as a `<style>` tag on the fly, and `SettingsDesign.svelte` (assumed) presumably has the textarea. The win is: this already exists, unlike IRCCloud which gates it behind Pro.

**Gap.** I don't know the surface area of `SettingsDesign.svelte`. **Open item**: audit it for: (a) textarea validation feedback, (b) "preview" toggle that scopes custom CSS to one buffer, (c) "reset to default" affordance.

**Recommendation.** Once audited, ensure the UI has:

```svelte
<textarea class="custom-css-input" rows="10" bind:value={customCSS} placeholder="/* e.g. */ .row.messageRow .content { color: #fff; }"></textarea>
<p class="custom-css-status" class:error={cssError} class:success={cssApplied}>
  {cssError ? `Syntax error: ${cssError}` : `Applied. Reload to undo.`}
</p>
```

CSS validation via a try/catch around `new Function(css)` or `CSSStyleSheet.replaceSync()` (modern API, no fallbacks needed — Chromium/Safari/Firefox all support it as of 2024).

**Effort:** Small-Meduim depending on what exists.
**Impact:** Low — power-user feature, but low effort if `_settings.scss` is right.

---

## Top 10 Prioritized Visual Improvements

| # | Title | Effort | Impact |
|---|---|---|---|
| 1 | **Themed `.self`/`.notice`/`.highlight`/`.warning` row backgrounds** (#1) | Small | High |
| 2 | **Per-row hover actions toolbar** (#2) | Medium | High |
| 3 | **Member list mode-prefix glyphs + away/match styling** (#3 + #14) | Small | High |
| 4 | **Themed connection-status pill banner** (#6) | Small | High |
| 5 | **Pending / failed message visual states** (#7) | Small | Medium-High |
| 6 | **Mobile 44×44 touch-target audit** (#10) | Trivial | Medium |
| 7 | **Empty-channel hint state** (#5) | Trivial | Medium |
| 8 | **Typing-indicator dot bounce with reduced-motion** (#9) | Trivial | Low-Medium |
| 9 | **Extend chat palette to 5+ themes** (#8) | Medium | Medium |
| 10 | **Away indicator in input nickcell** (#11) | Trivial | Low-Medium |

**Reading order for a designer-engineer pairing:** start with #3 + #14 (member list prefix) and #6 (status pill) — both high-impact, low-effort, no component-API changes. Then #1 (themed row backgrounds) for the single biggest "looks like IRCCloud" lift. Then #2 (hover toolbar) which is the longest individual PR but the most-lauded feature in IRCCloud feedback. Defer #8 (multi-theme) and #15 (custom CSS editor polish) until the chat looks canonical.

**Skip-worthy items:** #4 (date header gradient) is below the bar of effort-to-impact — the current `#333` solid is acceptable. #12 (settings hierarchy) is mostly maintenance, not visual improvement. #13 (sidebar chevron color) is micro-polish.