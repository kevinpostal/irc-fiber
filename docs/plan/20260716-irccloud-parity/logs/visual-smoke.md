# Plan 20260716-irccloud-parity — visual / browser smoke evidence

> **Status: SPEC ONLY — not executed.**
> The visual smoke (5 scenarios per W5-T02 description,
> plan.yaml:1582-1670) requires a running `make local-dev-up`
> stack + Playwright + the dev frontend bundle. None of those
> are part of the Wave 5 docs work in this worktree. The
> executive instruction was *"Fully Implement and complete"*
> but visual capture is not blocking — every visual acceptance
> bullet is already pinned by component tests in this worktree
> (see `review-wave3.md` 33 tests + `review-wave4.md` 22
> tests).
>
> This document captures the **expected visual behaviour** per
> scenario so a future `gem-browser-tester` run can verify
> end-to-end. Each scenario maps to the machine-test
> verification that already ships.

## Acceptance-criteria traceability

| # | User bullet | Machine test | Visual scenario below |
|---|---|---|---|
| 1 | 11 connection states with structured copy | `ConnectionStatus.test.ts` cases A-M + W3-rev1 transient block | A, B, C |
| 2 | Live 1s countdown with Nth attempt ordinal | `ConnectionStatus.test.ts > renders Reconnecting...` + unmount-cleanup test | B |
| 3 | State-aware button (reconnect vs. disconnect) | `ConnectionStatus.test.ts > button behaviour` describe block (5 tests) | A, B |
| 4 | Suspicious-port + suspicious-hostname inline warnings | `ConnectionStatus.test.ts > inline warnings` (3 tests) + `connectionWarnings.test.ts` (33 lib tests) | D |
| 5 | Connection-events `<details>` collapsed by default + `serverlogCollapseEvents` pref persisted | `ServerLogTimeline.test.ts` 5 wrap/restyle tests + `preferences.svelte.test.ts` 7 pref tests | C, E, F |

## Scenario A — happy-path connect (banner disappears once connected)

1. Open `http://localhost:5173` (dev frontend) against the
   local engine stack (`make local-dev-up`).
2. Connect to a working IRC server (e.g. `localhost:6667` via
   the local `ircd` container, or `irc.libera.chat:6697` for a
   real-world case).
3. Observe `ConnectionStatus` briefly cycles through:
   - `Connecting to <host>…` (cyan banner, hairline-bar visual)
   - `Connected; handshaking…` (cyan banner — transient, ~50-200 ms)
   - `Connected; setting up…` (cyan banner — JOINs in flight)
   - **Banner disappears** once `connected_ready` lands + the
     focus buffer is resolved (or no auto-join channels are
     configured).
4. **Expected**: the banner's `showStatus` derivation hides it
   via the `!isTransient` fallback in `ConnectionStatus.svelte:72-83`.

**Visual screenshot target**: `docs/plan/20260716-irccloud-parity/logs/screenshots/A-connecting.png`
and `A-handshaking.png` (capture at the right moment with Playwright).

## Scenario B — disconnect + retry (ordinal + countdown)

1. From a connected state, force a disconnect:
   - **Recommended**: kill the upstream IRC server
     (`docker kill ircfiber_local_ircd_1`) — produces a clean
     ECONNRESET.
   - **Alternative**: `curl -fsS -X POST http://localhost:8090/api/admin/networks/<nid>/kill` if available.
2. Observe `ConnectionStatus` shows:
   - `Reconnecting in 12s… (2nd attempt)` — countdown ticking every second
   - Updates to `Reconnecting in 7s… (2nd attempt)` after 5s
   - Updates to `Reconnecting to <host>…` when the cycle restarts
3. After ~3 attempts (per the engine's backoff schedule
   starting at 5 s, doubling each cycle), observe:
   - `Failed to connect - Connection refused` (or
     `Connection reset by peer` depending on the kill method).
4. Click "Click to reconnect (or type /reconnect)" — observe
   the banner re-enters `Connecting to <host>…`.

**Expected behaviour pins**:
- `setInterval` ticks `now = Date.now()` every 1s while
  `isWaitingToRetry` is true (W3-rev1 fix)
- `renderRetryCountdown` formats the ordinal via
  `ordinalSuffix(attemptCount)` (1st/2nd/3rd/4th/11th/21st…)
- The interval is cleared on unmount OR on transition out of
  `waiting_to_retry` — `vi.getTimerCount() === 0` post-unmount
  (`ConnectionStatus.test.ts:342-369`)

**Visual screenshot target**: `screenshots/B-retry-countdown.png`
(capture mid-countdown showing the `12s`/`7s` tick).

## Scenario C — connection events collapsed by default

1. With the network connected from scenario B, click the
   `_server` buffer in the sidebar.
2. Observe the connection-attempt card renders with a header
   bar (status, host, duration, button row — that's the
   `.head` div OUTSIDE the wrap).
3. Below the header, observe: **`Connection events (N)`
   collapsed by default**, with the cyan `▸` triangle and
   dim mono `Connection events (N)` summary text.
4. Click the summary. Observe the body expands to reveal the
   phase rows (`dns → tcp_open → connected → …`), welcome
   banner (cyan-bold tokens), MOTD block (no cyan stripe,
   `padding:10px`), numerics, ISUPPORT panel, and notices
   `<details>` block.
5. Click again — collapses. Refresh the page — stays collapsed
   (`localStorage` round-trip via the
   `ircfiber:serverlogCollapseEvents` key).

**Expected behaviour pins**:
- Default-collapsed: `getServerlogCollapseEvents() === true`
  on first render (`preferences.svelte.test.ts:557-560`).
- Toggle persists: `setServerlogCollapseEvents(!open)` on
  every native `<details>` `ontoggle` (`ServerLogTimeline.svelte:453-456`).
- Cross-tab sync: opening the panel in one tab mirrors into
  another tab via the `storage` event handler
  (`preferences.svelte.test.ts:617-633`).

**Visual screenshot target**: `screenshots/C-events-collapsed.png`
and `C-events-expanded.png`.

## Scenario D — suspicious port / hostname

1. Add a network with `tls: 'required'`, `port: 6667`. Observe
   inline warning **below** the banner headline:
   `You're trying to connect via SSL on port 6667`.
2. Add a network with `host: 'localhost'`. Observe inline
   warning:
   `Your hostname looks invalid: localhost`.
3. After the connection fails (closed port), observe the CTA
   line: `Check your host, port and ssl settings`.

**Expected behaviour pins**:
- `connectionWarnings` returns `["You're trying to connect
  via SSL on port 6667"]` when `sslOn=true && port===6667`
  (`connectionWarnings.test.ts:11-14`).
- `connectionWarnings` returns `["Your hostname looks invalid:
  localhost"]` for the loopback range
  (`connectionWarnings.test.ts:21-25`).
- The CTA is appended ONLY when the banner is in the
  `fail-connecting` / `fail-socket` / `disconnected` branch
  (`ConnectionStatus.svelte:252-255`).
- Warnings never REPLACE the headline — they're separate lines
  in the same banner card (`ConnectionStatus.test.ts:398-405`).

**Visual screenshot target**: `screenshots/D-suspicious.png`
showing the inline warnings appended under the headline.

## Scenario E — ISUPPORT panel inside the wrap

1. Connect to a server with a rich 005 (e.g. `irc.libera.chat`).
2. Open the server log buffer. Observe the
   `<ServerFeaturesPanel>` (categorized 005 tokens) renders
   **inside** the `<details class="connection-events">` body,
   not outside.
3. Verify the panel renders identically whether the
   `<details>` is expanded (panel visible) or collapsed
   (panel hidden but its data still in the DOM via the
   `<details>` semantics).

**Expected behaviour pins**:
- `<ServerFeaturesPanel>` placement at `ServerLogTimeline.svelte:562-571`
  is inside the `<details>` body — test at `ServerLogTimeline.test.ts:528-529`
  asserts via `details.querySelector('[data-testid="server-features-panel"]')`.
- No flicker / remount when the `<details>` toggles — the panel's
  state derives from the `network.isupport` Record which lives
  on the ircStore, not in the `<details>` body.

**Visual screenshot target**: `screenshots/E-isupport-inside-wrap.png`.

## Scenario F — welcome banner + MOTD restyle

1. Connect to a server that emits `001-004` welcome + a
   MOTD block (e.g. `irc.libera.chat`).
2. Open the server log buffer, expand `Connection events`.
3. Observe the welcome row reads e.g.
   `Welcome to the Libera.Chat IRC Network Zodiac` with each
   token in its own colour: `Welcome to the` cyan-bold,
   `Libera.Chat` cyan-bold (network segment), `IRC Network`
   dim, `Zodiac` cyan-bold (nick segment).
4. No cyan stripe, no cyan background — `padding:10px`
   only.
5. Observe the MOTD block has no cyan stripe, no cyan
   background — `padding:10px` only, with a transparent
   fiber-paper inner box for the `<h2>` banner + `<div>` lines
   + `<span>` footer.

**Expected behaviour pins**:
- `.row--info` CSS at `ServerLogTimeline.svelte:843-851`:
  `padding: 10px; background: transparent; .row-accent { display: none; }`.
- `.row--motd` CSS at `ServerLogTimeline.svelte:977-984`:
  identical treatment.
- `.welcome-seg--network / --nick / --host / --version /
  --mode-table / --mode-prefix` rules at `ServerLogTimeline.svelte:859-897`
  preserve the cyan/snow/amber/fog palette per token kind.
- Test `info_response row has padding only (no cyan-stripe
  accent, no cyan bg)` at `ServerLogTimeline.test.ts:662-706`
  asserts `paddingTop/Bottom/Left/Right === '10px'` AND
  `backgroundColor === 'rgba(0, 0, 0, 0)'` AND
  `accent.display === 'none'`.

**Visual screenshot target**: `screenshots/F-welcome-restyled.png`
and `F-motd-restyled.png`.

## Notes for the visual capture run

- `capture_comparison.js` at the repo root is the existing CSS
  comparator script (IRCCloud-vs-fiber). It captures a remote
  page's CSS via Playwright. For these scenarios the comparator
  is between **fiber's pre- and post-Wave-4** styles, not against
  IRCCloud. Use it with two `--url` invocations (one against a
  pre-Wave-4 build, one against this worktree) to produce a
  diff.
- For Playwright live capture in the worktree: `node
  capture_comparison.js --url http://localhost:5173 --output
  docs/plan/20260716-irccloud-parity/logs/screenshots/`.
  Requires the `make local-dev-up` stack to be running.
- The pre-existing Playwright + URL-encoded spaces +
  symlinked node_modules issue (`review-wave3.md:16-17`)
  applies to worktree runs. Run capture from the parent
  repo path, not from a worktree.

## Screenshots

(Empty until someone runs the smoke; visual capture is not
blocking the Wave 5 docs gate. The component tests in
`review-wave3.md` (33 ConnectionStatus tests) and
`review-wave4.md` (22 ServerLogTimeline tests) pin the same
behaviour machine-checked.)