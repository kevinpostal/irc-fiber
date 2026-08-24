# Plan 20260706-irc-rejoin-feel — IRCCloud-style "Click-to-Rejoin" UX

## Problem statement

IRC Fiber's channel rejoin UX diverges from IRCCloud's polish in three
measurable ways:

1. **The optimistic "Joining…" chip does not appear reliably.** Of the
   four entry points (URL nav, sidebar click, BufferHeader button,
   context-menu item, `/cycle /hop /rejoin` slash), only `maybeAutoJoinChannel`
   (URL/sidebar path) sets the full in-flight state. `BufferHeader.rejoin()`
   sets the chip-flag but not the belt-and-suspenders sync guard.
   `ChannelContextMenu.rejoin()` is a 2-line stub that calls `sendRaw`
   and `onClose`. Slash commands have the same bug.
2. **An engine sync snapshot arriving during the WS round-trip
   window can clobber the user-initiated `isJoined=true` back to
   `isJoined=false`.** The 2-of-2 sync confirm guard requires
   `pendingIsJoined=true; pendingConfirmations=2` to be set BEFORE the
   `sendRaw`, but only BufferHeader sets `joinInFlight`. Only
   `maybeAutoJoinChannel` sets the full quartet.
3. **The current user's own nick doesn't appear in the member panel
   until the engine's JOIN echo returns.** At click time we know we
   ARE about to be in this channel; the panel should show "you"
   immediately, not after the network round-trip.
4. **The Sidebar does not mirror `joinInFlight`.** If the buffer is
   `isJoined=false` (rejoin-time) it lives in the Inactive section
   with no visual cue that a JOIN is in flight.

## Root causes (verbatim code findings)

### RC1 — four rejoin entry points diverge from the canonical pattern

| Entry point | File:line | joinInFlight | pendingIsJoined | pendingConfirmations | markJoinPending | recordJoin | reconnect on disconnect |
|---|---|---|---|---|---|---|---|
| URL nav (sidebar click) — `maybeAutoJoinChannel` | `App.svelte:545-569` | YES | YES | not set (used only by JOIN echo at 1730) | YES | YES | skip-on-disconnect by design |
| BufferHeader Rejoin button | `BufferHeader.svelte:125-145` | YES | **NO** | NO | YES | YES | YES (explicit `if (!activeNetwork.connected) reconnectNetwork`) |
| Context-menu Rejoin item | `ChannelContextMenu.svelte:89-93` | **NO** | NO | NO | NO | NO | NO |
| `/cycle /hop /rejoin` slash | `slashCommands.ts:201-206` | NO | NO | NO | NO | NO | NO |

The canonical model — `joinInFlight=true; joinError=null; pendingIsJoined=true;`
plus `markJoinPending()` + `recordJoin()` before `sendRaw` — only
exists in `maybeAutoJoinChannel`. Three of the four entry points
under-init the state machine and rely on the JOIN echo to bring the
state up to date.

Critical consequence of `recordJoin` being skipped: when the engine
sends a `buffersToDelete` wire message during a WS resume, the
context-menu-initiated rejoin can be reaped because the
`activeJoinList` guard at `ircStore.svelte.ts:463-488` was never
populated.

### RC2 — sync-clobber window

At `ircStore.svelte.ts:1073-1509` `updateNetworkFromSync` reconciles
incoming snapshots. The clincher is at line 1383-1395:

```ts
const effectivePending =
  existingBuf.joinInFlight === true ? true : pending;
if (existingBuf.isPhantom) {
  if (existingBuf.joinInFlight !== true) {
    existingBuf.isJoined = incomingJoined;   // ← clobber
    existingBuf.isPhantom = false;
  }
} else if (effectivePending === undefined) {
  existingBuf.isJoined = incomingJoined;     // ← clobber (no guard)
}
```

`joinInFlight=true` alone saves phantom and real buffers. But the
2-of-2 confirm guard at line 1399-1411 (`pendingConfirmations`) only
kicks in when `effectivePending !== undefined` — meaning the explicit
guard is what produces the "two confirming syncs required before
clearing" semantics. Without `pendingIsJoined=true` AND
`pendingConfirmations=2`, a future engineer who clears `joinInFlight`
as part of an error path will silently lose the sync clobber guard.

### RC3 — self-nick deferred until JOIN echo

`updateChannelUsers` at `ircStore.svelte.ts:1710-1738` adds
`net.currentNick` to `buf.users` inside the `JOIN` for self branch
(self-nick dedup at lines 1720-1727):

```ts
} else if (cmd === 'JOIN' && joinNick === net.currentNick) {
  buf.isJoined = true;
  ...
  if (!buf.users.some(u => stripPrefix(u.nick) === net.currentNick)) {
    buf.users.push({ nick: net.currentNick, prefix: '', category: 'MEMBER', ... });
  }
```

This runs when the JOIN echo arrives — typically 50–300 ms after the
click. The 353 handler at line 1696-1701 already does in-place
promotion by `stripPrefix` dedup, so pre-populating at click time is
safe (the 353 will upgrade `nick` from `me` to `@me`).

### RC4 — Sidebar does not mirror `joinInFlight`

Four `<li class="buffer channel buffer-item">` sites at
`Sidebar.svelte:150 (Pinned), 251 (Active), 293 (Inactive), 364 (Archived)`
derive their styling solely from `isJoined !== false`. A buffer in the
Inactive section that has `joinInFlight=true` looks identical to one
that hasn't been touched. The DM/conversations site at line 324 is
`<li class="buffer conversation buffer-item">` and is deliberately
excluded — conversations never have `joinInFlight`.

## Wave structure

| Wave | Goal | Tasks |
|---|---|---|
| **1** | Extract `initiateRejoin(networkId, name, opts)` helper in `ircStore.svelte.ts`; refactor 4 entry points (BufferHeader, ChannelContextMenu, slashCommands, maybeAutoJoinChannel) to delegate. Pre-populate self-nick inside the helper. Drop the PART-before-JOIN in `/cycle /hop /rejoin`. | `W1-T01` |
| **2** | Sidebar: add `.buffer-item--joining` modifier class + CSS at all four channel sites (150, 251, 293, 364). Pre-populate work lives in W1's helper. | `W2-T01` |
| **3** | Tests: 10 new state-machine tests in `ircStore.svelte.test.ts`; extend component tests for BufferHeader (chip + flags), ChannelContextMenu (state transitions), Sidebar (joining class), slashCommands (file created with 3 cases). | `W3-T04`, `W3-T05` |
| **4** | Verification: browser smoke (4 scenarios) + lightweight reviewer check. | `W4-T01`, `W4-T02` |

Total: **7 tasks across 4 waves**, ~22 workstream events including
test cases.

## File references

| File | Why |
|---|---|
| `frontend/src/stores/ircStore.svelte.ts` | Hosts the new `initiateRejoin` helper + `prePopulateOwnNick` colocated with the existing `markJoinPending`/`recordJoin` siblings. |
| `frontend/src/components/BufferHeader.svelte` | `rejoin()` (line 125) becomes a one-liner delegate with `allowReconnect: true`. |
| `frontend/src/components/ChannelContextMenu.svelte` | `rejoin()` (line 89) becomes a one-liner delegate with `allowReconnect: false`. |
| `frontend/src/lib/slashCommands.ts` | `/cycle /hop /rejoin` (line 201) delegates to the helper. |
| `frontend/src/App.svelte` | `maybeAutoJoinChannel` (line 545) keeps its URL-nav guards and delegates body to the helper. |
| `frontend/src/components/Sidebar.svelte` | Four `buffer-item` channel sites (lines 150 Pinned, 251 Active, 293 Inactive, 364 Archived) get the `:class={ 'buffer-item--joining': b.joinInFlight }` modifier + a CSS block. Conversations site (line 324) deliberately excluded (DMs never have `joinInFlight`). |
| `frontend/src/stores/ircStore.svelte.test.ts` | New `describe('initiateRejoin', ...)` block (after line 1348). 10 cases including pre-pop / JOIN-self-echo / 353 sequence + WS-reconnect race. |
| `frontend/src/components/BufferHeader.test.ts` | Extend the existing 'clicking Rejoin' test (line 287) with chip + flags assertions. |
| `frontend/src/components/ChannelContextMenu.test.ts` | New test exercising click → state transitions. |
| `frontend/src/components/Sidebar.test.ts` | New `describe('joining modifier')` block. |
| `frontend/src/lib/slashCommands.test.ts` | NEW file. Three cases (`/cycle`, `/hop`, `/rejoin`) asserting `joinInFlight=true`, `pendingJoins.has`, `sendRaw('JOIN')` exactly once. |

## Acceptance criteria (mapped to plan tests)

| User-stated acceptance criterion | Plan test(s) | Mechanism |
|---|---|---|
| Within 50 ms after click, BufferHeader shows "Joining #chan…" chip | W3-T04 test #1; W3-T05 BufferHeader extension; W4-T01 scenario A | BufferHeader reads `joinInFlight` directly via `isJoining = $derived(!!buf.joinInFlight)` |
| Within 50 ms after click, Sidebar `.buffer-item--joining` class present | W3-T05 Sidebar describe block; W4-T01 scenario A | Svelte 5 reactive class binding — triggers on `b.joinInFlight` flip |
| After JOIN echo arrives, member panel includes current nick within one tick (even before 353) | W3-T04 test #6 + #7; W4-T01 scenario A | `prePopulateOwnNick` called inside `initiateRejoin`; uses stripPrefix-safe dedup so 353 in-place promotion is preserved |
| Engine sync with `isJoined:false` does NOT clobber back to false | W3-T04 test #8 | pendingIsJoined+pendingConfirmations set BEFORE sendRaw |
| Disconnected Rejoin kicks `reconnectNetwork()` AND queues JOIN | W3-T04 test #4; W4-T01 scenario C | `opts.allowReconnect` flag — BufferHeader passes true; context-menu / slash pass false |
| 473 (invite-only): chip shows "Invite-only channel" without flicker | W4-T01 scenario D | The join-inflight and join-error chips render in an `{#if}{:else if}` chain so the failure response overrides the in-flight chip directly |

## Deploy notes

- **No engine redeploy needed.** Frontend-only changes.
- **`make update`** in the parent makefile will compile frontend dist
  assets and push them to the gateway container via the existing
  SSH tar pipe. No backend container restart.
- **Rollout:** ship `make update`; verify by clicking Rejoin on a
  parted channel in production. The chip should appear within 50 ms
  and the sidebar entry should italicize.
- **Rollback:** single-commit revert; no state-machine migration
  needed because the new flags (`pendingIsJoined`,
  `pendingConfirmations`) are nullable and the JOIN-echo handler at
  line 1730 still sets them.
- **Observability:** the new pre-populate + sync guard adds zero log
  lines; behavior changes are entirely visible at the DOM boundary
  (`.join-inflight-chip`, `.buffer-item--joining`). SigNoz dashboard
  doesn't need updates.

## Risks (top 2)

1. **Refactor regression on W7-T01 / W1-T06 invariants.** If the
   helper loses `recordJoin` or `markJoinPending` on any of the four
   delegates, a WS-resume `buffersToDelete` wire could reap
   freshly-rejoined buffers (regression of
   `handleBuffersToDelete` guard tests at
   `ircStore.svelte.test.ts:1145-1240`). Mitigation: W3-T04 test
   #9 explicitly exercises this.
2. **Self-nick duplicate after 353.** If pre-populate dedup drifts
   from the existing `stripPrefix` rule, a 353 with `@me` can produce
   a duplicate entry. Mitigation: W3-T04 test #7 explicitly runs the
   pre-pop → 353 sequence and asserts exactly one entry.

## Behavior changes to document in CHANGELOG / deploy notes

1. **`/cycle /hop /rejoin` semantics change.** Previously these commands
   issued `PART <chan>` followed by `JOIN <chan>` (see
   `slashCommands.ts:205-206`). After this plan, they issue only
   `JOIN <chan>` via the `initiateRejoin` helper. Justification:
   IRCCloud semantics for `/cycle` is "rejoin this channel" — the
   PART-before-JOIN would clobber `isJoined=true` mid-flow and break
   the optimistic "Joining…" chip. Key extraction is unchanged. The
   `/rejoin` alias matches user expectation that this IS the "just
   rejoin" command.

## Assumptions made during planning

1. The sync-clobber architecture (2-of-2 sync confirm guard at
   `ircStore.svelte.ts:1378-1412`) is correct. We make entry points
   conform rather than redesign.
2. `maybeAutoJoinChannel` (App.svelte:545-569) is the canonical
   pre-existing pattern. We delegate to a shared helper rather than
   rewrite — saves duplicating the joinInFlight+pendingIsJoined writes
   across four files.
3. Existing chip UI in BufferHeader (line 174-184) is sufficient. We
   keep render location and styling, only ensure the state flags are
   correctly set by every rejoin entry point.
4. Sidebar styling for `.buffer-item--joining` follows the visual
   vocabulary of `.buffer-item.unread` / `.buffer-item.highlight`
   (italic + reduced opacity). No design-system work needed.
5. The slash-command `/cycle /hop /rejoin` is also a rejoin entry
   point and shares the same consolidation. Without it, `/cycle`
   would silently drop the JOIN when typing on a disconnected network.
6. The "no flicker on 473" property is structural: `{#if}{:else if}`
   in BufferHeader.svelte:174-184 — no transient "Joining…" state
   when the failure response arrives within 200 ms. No animation
   suppression code needed.
7. 50 ms timing claims rely on Svelte 5 tick scheduling, which is
   synchronous within a microtask cycle. Vitest-browser assertions
   prove the DOM transition without needing explicit timers.
8. The 353 in-place promotion at line 1696-1701 already handles the
   case where pre-populated `me` is upgraded to `@me`. Pre-pop uses
   the same `stripPrefix` dedup rule.
