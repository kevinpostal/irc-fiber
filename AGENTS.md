# IRC Fiber — Server features UI overhaul

The "Server features" panel in the connection-attempt timeline used
to dump `005 (RPL_ISUPPORT)` tokens as a flat monochrome list. That
list was hard to scan and provided no documentation — a token like
`ACCOUNTEXTBAN=account,a` or `MAXLIST=b:250,e:250,I:250` was opaque to
anyone who hadn't memorised RFC 2811/2812.

The overhaul builds a categorised, searchable panel backed by a
typed catalog of every well-known ISUPPORT token + IRCv3 capability,
each entry carrying human description, RFC/IRCv3 references, and a
click-through detail drawer modelled on the IRCv3 spec-page format
(`https://ircv3.net/specs/extensions/away-notify.html`).

## Architecture

```
Engine (D)                                  Frontend (TS)
─────────────────────────                   ────────────────────────
case "005": parse every token  ←───────     frontend reads `network.isupport`
store on PersistentIRCClient               (a `Record<string,string>`
emit ISUPPORT event mid-stream             already typed on `Network`).
                                          categorize → CategorizedGroup[]
synced via NetworkStateSnapshot              → ServerFeaturesPanel
persisted in Redis snapshot                  → CategoryCard × N
survives hard restart via snapshot           → click a row → IsupportDetailDrawer
```

Files:

| File | Purpose |
|---|---|
| `frontend/src/lib/isupportCatalog.ts` | Typed DB of every well-known ISUPPORT token + IRCv3 capability (~80 entries) — name, category, kind, description, RFC/IRCv3 link |
| `frontend/src/lib/isupportCategorize.ts` | Buckets a flat isupport map into renderable `Category × Features[]`. Stays pure: same input → same output |
| `frontend/src/components/ServerFeaturesPanel.svelte` | Categorised grid view with search, status badges, collapse-all |
| `frontend/src/components/IsupportDetailDrawer.svelte` | IRCv3-style detail page for each feature — title, abstract, on-this-server value, RFC/IRCv3 link |
| `source/ircfiber/irc/connection.d` | Engine stores the full map; emits `ISUPPORT` synthetic event |
| `source/ircfiber/models/irc_event.d` | `IRCRawEvent.makeIsupport` factory — JS-object payload |
| `source/ircfiber/redis/protocol.d` | `NetworkStateSnapshot.isupport: string[string]` |
| `source/ircfiber/engine/state.d` | Snapshot writer publishes the map with each heartbeat |
| `source/ircfiber/api/websocket.d` | Sync payload `netObj["isupport"]` ships it to every fresh WS connection |
| `frontend/src/lib/messageHandler.ts` | Dispatches the `ISUPPORT` event into `applyIsupportUpdate()` |
| `frontend/src/stores/ircStore.svelte.ts` | `applyIsupportUpdate()` writes the engine's parsed map onto `net.isupport` |
The legacy `ServerFeatures` struct (6 hardcoded fields:
NETWORK, PREFIX, CHANMODES, NICKLEN, TOPICLEN, CHANLIMIT) is kept
on the engine side for backward compatibility with code that
pre-dated the catalog. New code consumes `isupportMap` /
`getIsupport()`.

## Why this avoided the "parse 005 in the frontend" smell

Before this change, `applyIsupport` in the engine only stored 6
ISUPPORT tokens — everything else (`DYNAMITE`, `HOOKS`, `MONITOR`,
`CHATHISTORY`, etc.) was silently dropped at the engine level. The
frontend had three options:
1. Re-parse raw 005 message text from the `_server` buffer
2. Maintain a separate ISUPPORT-derivation layer per IRCd
3. **Have the engine emit a parsed `string[string]` map** ✅

We picked option 3. The 005 handler now:
1. Stores every token (case-insensitive, uppercased for catalog lookup)
2. Mirrors the legacy 6 fields onto `ServerFeatures` for back-compat
3. Emits a synthetic `ISUPPORT` WS event after the 005 stream ends
4. Ships the map in the `NetworkStateSnapshot` for resume (survives hard restart via Redis)
The frontend panel reads `network.isupport` directly. The 005 message
parser in `isupportFromMessages` remains as a fallback for historical
displays that surface a pre-synced server-log timeline.

## Categories

The catalog groups tokens into 11 buckets (see
`ISUPPORT_CATEGORIES`):

| ID | Purpose | Examples |
|---|---|---|
| `server-identity` | Network / case-mapping identifier | `NETWORK`, `CASEMAPPING` |
| `channel-naming` | Prefix chars, name / topic length | `CHANTYPES`, `CHANNELLEN`, `TOPICLEN`, `KICKLEN`, `CHANLIMIT`, `STATUSMSG`, `MAXCHANNELS` |
| `user-limits` | Nick / username / away length | `NICKLEN`, `MAXNICKLEN`, `MINNICKLEN`, `USERLEN`, `HOSTLEN`, `AWAYLEN` |
| `case-mapping` | RFC 1459 / strict / ascii | (single token: `CASEMAPPING` — kept visible) |
| `channel-modes` | `PREFIX`, `CHANMODES`, `MODES`, `MAXLIST` | (type categorisation) |
| `channel-bans` | Ban / exception / invite-override tokens | `EXCEPTS`, `INVEX`, `EXCEPTSEXTBAN`, `BANWIDTH` |
| `user-modes` | Client toggles | `USERMODES` (rare) |
| `messages` | Server-side history / msg-id types | `CHATHISTORY`, `MSGREFTYPES`, `CLIENTTAGDENY` |
| `capabilities` | Bare flags | `KNOCK`, `DEAF`, `BOT`, `CALLERID`, `REGNICK`, `SILENCE`, `WALLCHOPS`, `ACCEPT`, `WHOX`, `CPRIVMSG`, `SAFELIST`, `ELIST`, `UTF8ONLY`, `UTF8MAPPING`, `LANGUAGE`, `FNC`, `ETSDELIM`, `WATCH`, `MONITOR` |
| `extensions` | IRCv3-era | (none currently — placeholder for future) |
| `server-specific` | Catch-all for tokens we don't catalog | `DYNAMITE`, `URANIUMREFINERY`, etc. (SuperNets custom tokens) |

## Quickstart for adding a new token

1. Open `frontend/src/lib/isupportCatalog.ts`.
2. Append an entry to `ISUPPORT_CATALOG`:
   ```ts
   {
     key: 'WALLCHOPS',          // upper-case canonical
     category: 'capabilities',  // pick from ISUPPORT_CATEGORIES
     kind: 'flag',              // flag | int | string | enum | mode-list | prefix-list | pair | mask | language | time
     title: 'WALLCHOPS command',
     short: 'Server supports sending PRIVMSGs only to channel ops',
     detail: 'WALLCHOPS #chan :text sends a status message to channel ops only; survives across +m / moderated / silenced normal users.',
     rfc: 'https://…',          // optional
     ircv3: 'https://…',        // optional
     since: 'RFC 2812',         // or 'IRCv3 3.0'
     status: 'extended',        // core | extended | draft | legacy | ircv3 | undefined
   }
   ```
3. The panel re-renders automatically — no other code change
   required. The catalog is the single source of truth and is
   indexed once into a Map for `lookupIsupport()`.

## Known issues / open questions

| Issue | Notes |
|---|---|
| Engine-side `dub test` (Dub-managed) currently fails to build | Pre-existing on `main`; not related to this change. `make build --config=…` works (`engine-handoff` removed 2026-08-08). |
| Some custom IRCds emit unparseable 005 streams | `splitIsupportText` falls back to a single-token pass-through so the timeline at least shows *something*. The catalog marks unknowns as `server-specific` so the user knows they're nonstandard. |
| Bare flag in concatenated text (e.g. `AWAYLEN=307KNOCK`) | Catalog ambiguity resolved via `lookupIsupport`-aware splitter — see `splitIsupportText` for the full disambiguation rules. Tested via the `splitIsupportText` unit-test suite. |

---

# IRC Fiber — Connection status & server log (IRCCloud parity)

The "Connecting / server log" surface used to be a 3-state banner
(`Away / Connecting / Disconnected`) and an always-expanded
connection-attempt card. The 3-state banner silently dropped retry
timing, ordinal attempts, structured failures, suspicious-port /
suspicious-hostname warnings, and the entire `connected` →
`connected_joining` → `connected_ready` handshake window. The
connection-attempt card dumped welcome / MOTD / numerics / ISUPPORT
/ notices as plain rows with cyan chips and a cyan left stripe,
which made the welcome banner read like a CTA instead of an
informational header.

The overhaul makes the banner 11-state, the timeline collapsed by
default under a single hairline-bar `<details>` (persisted via
`serverlogCollapseEvents`), and the welcome / MOTD rows typographic
(padding + transparent background + mono prefix instead of chip +
stripe). All while keeping the fiber palette — no new CSS tokens,
no IRCCloud fonts; only the IRCCloud visual grammar.

## Architecture

```
Engine (D)                                      Frontend (TS)
─────────────────────────                       ────────────────────────
backoff loop:                                   ircStore.svelte.ts:
  state ← waiting_to_retry                        applyRetryStatus(nid, rs)
  emit CONNECTION_RETRY_STATUS                    applyFail(nid, fi)
  on reconnect success:                         messageHandler.ts:
    state ← connecting                            dispatch retry/fail
    emit ZeroClear                                  into the store
disconnect site:                                ConnectionStatus.svelte:
  build FailInfo{type, reason, ...}               11 BannerKind branches
  emit CONNECTION_FAIL                          serverlogCollapseEvents pref
  + emit legacy disconnectReason                  (preferences.svelte.ts)
snapshot writers:                               ServerLogTimeline.svelte:
  NetworkStateSnapshot.retryStatus                <details bind:open>
  WS sync: netObj["retryStatus"]
```

Files:

| File | Purpose |
|---|---|
| `source/ircfiber/irc/connection.d` | Engine: `waiting_to_retry` enum value; `attemptCount`/`nextRetryAtMs` fields; `CONNECTION_RETRY_STATUS` emit at every retry sleep; zero clear on every `backoff.reset()` site |
| `source/ircfiber/models/irc_event.d` | `IRCRawEvent.makeConnectionRetryStatus` + `makeConnectionFail` factories; `FailInfo` struct (type / reason / killedReason / nested sslVerifyError) |
| `source/ircfiber/redis/protocol.d` | `NetworkStateSnapshot.retryStatus: {attemptCount, nextRetryAtMs, delayMs}` nullable field |
| `source/ircfiber/engine/state.d` | Snapshot writer reads `client.getRetryStatus()` and ships it on each heartbeat |
| `source/ircfiber/api/websocket.d` | Fresh-client sync payload `netObj["retryStatus"]` (when present, absent otherwise — back-compat with older engine builds) |
| `frontend/src/lib/connectionWarnings.ts` | `renderReason`, `renderSSLVerify`, `renderRetryCountdown`, `connectionWarnings`, `FAIL_TYPES` — pure helpers, no Svelte imports |
| `frontend/src/types.ts` | `Network.retryStatus`, `Network.failInfo`, `Network.badRetry`, `Network.focusOnMakeBuffer`, `Network.ip` (all optional for back-compat) |
| `frontend/src/lib/messageHandler.ts` | Dispatches `CONNECTION_RETRY_STATUS` (zero payload → clear) and `CONNECTION_FAIL` (writes `failInfo`) |
| `frontend/src/stores/ircStore.svelte.ts` | `applyRetryStatus(networkId, rs)` (null clears `retryStatus` AND `failInfo` per TG5 invariant) and `applyFail(networkId, fi)` |
| `frontend/src/stores/preferences.svelte.ts` | `serverlogCollapseEvents` $state + `getServerlogCollapseEvents` / `setServerlogCollapseEvents` + localStorage `ircfiber:serverlogCollapseEvents` key + cross-tab `storage` event handler |
| `frontend/src/components/ConnectionStatus.svelte` | 11-state banner; `BannerKind` union; live countdown via `$effect` + `setInterval` cleanup on unmount OR retryStatus→null; hairline-bar visual; state-aware button (reconnect / disconnect) |
| `frontend/src/components/ServerLogTimeline.svelte` | `<details class="connection-events">` wrap (phases + welcome + motd + numerics + isupport + notices); typographic `.row-type-prefix` instead of `.row-tag` chip; padding-only `.row--info` and `.row--motd` (no cyan stripe, no cyan bg) |

## Behavior matrix

Banner states (W3-T01 / W3-rev1):

| BannerKind | connectionState | Headline |
|---|---|---|
| `away` | any + `isAway` | `Away` |
| `queued` | `queued` | `Connection queued; waiting our turn…` |
| `connecting` | `connecting` | `Connecting to {host}…` (or `Reconnecting to {host}…` if a prior disconnect happened) |
| `handshake` | `connected` (001 received, no JOINs yet) | `Connected; handshaking…` |
| `connected-joining` | `connected_joining` | `Connected; setting up…` |
| `connected-ready` | `connected_ready` + `focusOnMakeBuffer` set | `Connected; waiting to join {chan}…` |
| `quitting` | `quitting` | `Quitting…` |
| `ip-retry` | `ip_retry` | `Connecting to {ip} failed ({err}); resolving a new IP…` |
| `retry` | `waiting_to_retry` + retryStatus populated | `Reconnecting in {N}s… ({Nth} attempt)` — live 1s countdown |
| `retry-giveup` | `waiting_to_retry` + retryStatus cleared | `Reconnecting…` (static fallback) |
| `fail-killed` | `failInfo.type === 'killed'` | `Disconnected - Killed: {killedReason}` |
| `fail-ssl` | `failInfo.sslVerifyError` present | `Strict transport security error: {renderSSLVerify(...)}` |
| `fail-blocked` | `failInfo.type === 'connection_blocked'` | `Disconnected - Connections to this server have been blocked` |
| `fail-connecting` | `failInfo.type === 'connecting_failed'` | `Failed to connect - {renderReason(reason)}` |
| `fail-socket` | `failInfo.type === 'socket_closed'` | `Disconnected: {renderReason(reason)}` |
| `disconnected` | disconnected (no failInfo) | `Disconnected: {renderReason(disconnectReason)}` (legacy string fallback) |

Inline warnings (always appended, never replace the headline):

| Condition | Warning |
|---|---|
| `tls === 'required'` (or `'enabled'`) AND `port === 6667` | `You're trying to connect via SSL on port 6667` |
| Host matches `localhost` / `127.0.0.1` / `::1` / RFC1918 / `.local` / `.lan` / `.internal` | `Your hostname looks invalid: {host}` |
| BannerKind ∈ `{fail-connecting, fail-socket, disconnected}` | `Check your host, port and ssl settings` |

Connection-events `<details>` wrap (W4-T01):

| Toggle | Persisted in | Default |
|---|---|---|
| `<details class="connection-events">` `open` attribute | `localStorage[ircfiber:serverlogCollapseEvents]` (global, not per-network) | `false` (collapsed) |
| Per-attempt collapse (`serverlogCollapsedMap`) | `localStorage[ircfiber:collapsed:*]` (per-attempt keys) | `false` (expanded) |
| `<details class="notices-details">` (inner notices block) | in-component `$state` only | `true` (expanded) |

Welcome / MOTD / numeric row treatment (W4-T01):

| Row class | Padding | Background | Accent | Prefix |
|---|---|---|---|---|
| `.row--info` (001-004) | `10px` | transparent | hidden | `<span class="welcome-seg welcome-seg--{kind}">` per-segment colour (network / nick / host / version / modes) |
| `.row--motd` | `10px` | transparent | hidden | `<.motd-banner>` kicker + title (mono `MOTD` / `Message of the Day` / `{N} lines`) |
| `.row--stat` (other numerics 251/252/…) | inherited | inherited | inherited | cyan `<span class="row-cmd">{NNN}</span>` + cyan-bold digit runs in body via `parseNumericStat` |
| `.row` (phase rows) | inherited | inherited | inherited | mono `<span class="row-type-prefix">{phaseToLabel(...)}</span>` (replaces cyan `.row-tag` chip) |

## Acceptance criteria

W3-T01 + W3-rev1 + W4-T01 acceptance bullets — all 5 user-stated
criteria map to machine tests:

| User bullet | Test / surface |
|---|---|
| Banner shows 11 connection states with structured copy | `ConnectionStatus.test.ts` cases A-M (banner states) + describe block "transient state coverage" (W3-rev1) |
| Live 1s countdown during retry (with Nth attempt ordinal) | `ConnectionStatus.test.ts > renders Reconnecting in <N>s... (<ordinal> attempt) with live countdown ticks` |
| State-aware button (reconnect vs. disconnect for badRetry) | `ConnectionStatus.test.ts > button behaviour` describe block (5 tests) |
| Suspicious-port + suspicious-hostname warnings inline | `ConnectionStatus.test.ts > inline warnings` describe block + `connectionWarnings.test.ts` (lib, 33 tests) |
| Connection-events `<details>` collapsed by default + `serverlogCollapseEvents` pref persisted in localStorage | `ServerLogTimeline.test.ts > wraps-all-rows` / `collapsed-when-pref=true` / `expanded-when-pref=false` / `toggling-the-summary-persists` / `mirrors-external-pref-flips` + `preferences.svelte.test.ts > serverlogCollapseEvents` (7 tests) |

## Quickstart for adding a new banner state

1. Add the state to `Network.connectionState` union in
   `frontend/src/types.ts` (the 11-entry `ConnectionState` type).
2. Add a `BannerKind` case in `ConnectionStatus.svelte`
   (`type BannerKind = ...`). Branch order matters: `fail-*` arms
   must come before `connecting`/`disconnected` because the
   `failInfo` discriminator wins when both are present.
3. Add the case in the `headline` switch — copy the IRCCloud line
   from `app/src/view/connectionstatusview.js:64-123` and adapt.
4. Add `isFoo = $derived(activeNetwork?.connectionState === 'foo')`
   plus add it to the `isTransient` `||` chain if the banner must
   stay visible during the new state.
5. Add a test in `ConnectionStatus.test.ts` `describe('ConnectionStatus — banner states')` (or the W3-rev1 transient block) that constructs a Network with the new state and asserts the rendered headline.
6. If the engine emits a new structured fail-info variant, also add
   to `FAIL_TYPES` in `frontend/src/lib/connectionWarnings.ts` and add
   a `renderReason` translation if the user-facing copy diverges
   from the engine key.

Engine emit sites live in `source/ircfiber/irc/connection.d` at the
backoff loop (`auto deadline = Clock.currTime + delay;` site, line
~1595) and at the attempt-connection paths. New fail reasons go in
the reason-text → `FailInfo{type,...}` parser around line ~4113.

## Known issues / open questions

| Issue | Notes |
|---|---|
| Engine `dub test` (Dub-managed) fails to build on main | Pre-existing; not related to this work. `dub build --config=connection-registration-test` works. The Wave 1 retry/fail work landed on `w1-t01-engine-retry-fail` and merged via PR; smoke is the `dub run` config |
| IRCCloud's dusk palette tokens (`#1d4063`, `#3473b2`, `#6199d1`, `#17334f`, `#c4d9ee`, `#dbb300`, `#af3a00`) are REFERENCE colours only | They are NOT introduced as new CSS variables — the implementation maps to existing fiber tokens (`--fiber-blue`, `--fiber-blue-soft`, `--fiber-amber`, `--fiber-cloud`, `--fiber-mist`) |
| Per-attempt `serverlogCollapsedMap` keys are independent of the global `serverlogCollapseEvents` pref | They coexist: per-attempt `serverlogCollapsedMap[networkId:eid]` controls the per-attempt summary's open state; global `serverlogCollapseEvents` controls the new `<details class="connection-events">` open state. Don't try to unify the two |
| `--fiber-amber-soft` is referenced by `.banner--fail` but not yet defined in `homepage.yml` | CSS falls back transparently to `rgba(...)` if the token is absent. Tracked as a 1-line palette addition (file a follow-up PR when ready) |
| Banner button label says `Click to reconnect (or type /reconnect)` for the `retry-giveup` state | This is intentional — IRCCloud's "gave up" UI offers the user a manual retry button. The engine is no longer auto-retrying; user must click to start a new attempt |
| `focusOnMakeBuffer` engine emit is best-effort, not always shipped | Banner falls back to the generic `Connected; waiting to join…` when the field is empty or `'*'`. Engines that don't ship this still get a sane banner |
| Client tests in worktrees cannot run (Playwright + URL-encoded spaces + symlinked node_modules) | Pre-existing environmental issue; run client tests from the parent repo path, not from a worktree. Confirmed on w3 and w4 waves |

---

# IRC Fiber — Testing Guide

## Test Suites

Two vitest projects under `frontend/`:

- **`lib`** — Pure utility tests, no DOM, runs in Node (`src/lib/**/*.test.ts`)
- **`client`** — Svelte component + store tests, runs in headless Chromium (`src/**/*.test.ts`, `*.svelte.test.ts`)

```bash
cd frontend

# Run all tests
npm test

# Lib only (fast, no browser)
npm run test:lib

# Client only (Svelte components + stores)
npm run test:client

# Watch mode
npm run test:watch
```

## Testing Patterns

### Lib tests (Node, fast)
Use vitest directly — no browser context needed:
```typescript
import { describe, expect, it } from 'vitest';
import { mentionNicks } from './autolinker';

describe('mentionNicks', () => {
  it('wraps a single mention', () => {
    const result = mentionNicks('hello @Alice', new Set(['alice']));
    expect(result).toContain('mention');
  });
});
```

### E2E / Visual Tests (Playwright)
Capturing + comparing CSS between IRCCloud and our app:
```bash
# Capture both pages and produce comparison_full.json
node capture_comparison.js
```

Key scripts in project root:
- `capture_comparison.js` — Full CSS comparison (IRCloud vs local)
- `capture_css.js` — Initial CSS capture
- `test_mention.js` — Verify `.mention` elements render correctly
- `check_links.js` — Inspect IRCCloud link styling

### Run lib tests for a single file
```bash
npx vitest run --project=lib src/lib/autolinker.test.ts
```

## Debugging

Add `console.debug()` in Svelte components and capture via Playwright:
```typescript
page.on('console', msg => { if (msg.text().includes('[tag]')) logs.push(msg.text()); });
```

The `capture_comparison.js` script also captures IRCCloud's live CSS for reference.

## Jul 8 2026 bug fixes — full audit & performance pass

Five production bugs fixed in one pass. All time-to-connect measurements taken
from the live OVH engine against meth.cat (remote, ngircd) and IRC Fiber
(local, ergo-2.18.0).

## Direct engine IRC connection

The engine opens IRC TCP/TLS sockets directly via
`happyEyeballsConnect()` and `createTLSStreamWithTimeout()` in
`source/ircfiber/irc/connection.d`. No holder daemon, no Unix-domain IPC.
When the engine restarts (hard restart via `docker restart`):

- **All networks (plain TCP and TLS)** disconnect and auto-reconnect via
  the engine backoff loop. Users see a brief `Connecting…` / `Reconnecting…`
  card. This is intentional — the `SCM_RIGHTS` FD-transfer handoff
  (`source/ircfiber/engine/handoff.d`) was removed 2026-08-08 as legacy
  fragile code (Tailscale-bind redis bug, stale `irc:control:ovh` LPUSH
  failures). Single-host deploys do not need zero-disconnect.

The archived handoff daemon lives under `archived/conn-holder/` and the
removed `handoff.d` / `reload_orchestrator.d` / `exec_reload.d` are kept
only for reference — do not reintroduce `IRCFIBER_RELOAD_FROM_PID` or
`make engine-handoff`.

- `parser-test`           — IRC line parser
- `consumer-test`         — reconnect-dedup helpers
- `connection-registration-test`   — **NEW**: ConnectionServer.registrationUnavailableFor JSON contract for the admin registration-stuck surface
- `observability-test`    — OTel metrics pipeline

For end-to-end tests that require a live IRC server, use the scripts in
`scripts/e2e/` (see the e2e section at the bottom of this file).

### Connection registration timeout (RFC 2812)

`source/ircfiber/irc/connection.d` enforces a hard
`REGISTRATION_OVERALL_TIMEOUT_SECS = 30` on the CAP + NICK + USER + SASL
handshake. RFC 2812 §2.3 explicitly states: *"client should expect a
reply as specified but it is not advised to wait forever for the
reply"*. Before this, a black-holed server (open TCP, never sends 001)
would wedge the network's join state forever and operators would see
`Joining #channel…` with no clue why.

When the timeout fires, the engine:
1. Sets `client.registrationTimeoutSince` to unix-ms
2. Throws to let the connection loop's exponential backoff schedule a
   retry
3. Emits a `ircfiber.registration.timeout` counter (tagged by
   network / host)
4. Surfaces the network in
   `ConnectionServer.registrationUnavailableFor`, surfaced via
   `GET /api/admin/servers` so the admin SPA can show "this network
   is stuck in registration" with a real reason

Run `python3 scripts/e2e/registration_timeout.py` to verify end-to-end:
the test stands up a local Python TCP listener that accepts but never
sends 001, configures a network pointing at it, and asserts the
engine's `registrationUnavailableFor` array contains the network
within 75s.

---

# IRC Fiber — Engine Lifecycle (Hard Restart Only)

> **Handoff removed (2026-08-08).** The previous `SCM_RIGHTS` graceful
> hot-reload (`engine-handoff`, `reload_orchestrator.d`, `handoff.d`,
> `exec_reload.d`, `IRCFIBER_RELOAD_FROM_PID`, Unix socket at
> `/tmp/ircfiber-handoff-<serverId>.sock`) has been deleted. It was
> fragile, left stale `irc:control:ovh` LPUSH failures on hosts where
> redis binds to Tailscale IP `198.51.100.1`, and is unnecessary for a
> single-host deployment. **All engine deploys now use hard restart:**
> `docker restart ircfiber-engine-ovh` (+ gateway). Plain/TLS IRC
> connections will briefly disconnect and auto-reconnect via the engine
> backoff loop. Use `make update` (gateway+engine) or `docker restart`
> directly — never `make handoff` / `engine-handoff`.

The files `source/ircfiber/engine/handoff.d`,
`reload_orchestrator.d`, `exec_reload.d` and the `pauseForHandoff` /
`adoptAndStart` / `forcePostHandoffQuit` paths in `connection.d` /
`manager.d` are legacy and must not be reintroduced. The deploy
playbooks `deploy-handoff.yml` and the `handoff` Makefile target are
removed; they previously did `redis-cli LPUSH irc:control:ovh` without
`-h 198.51.100.1` and always failed on OVH.

# IRC Fiber — DM Persistence Invariant (2026-08-08)

**Bug:** Outgoing DM with `echo-message` cap was stored under your own
nick, not the recipient, so refresh lost it. Root cause:
`engine/source/ircfiber/irc/parser.d:208` did
`event.channel = nick` for all non-channel `PRIVMSG` (correct for
incoming, wrong for your own echo `:you!... PRIVMSG target :text` where
`nick==sessionNick`). `bufferManager.appendIRCEvent` then wrote
`scrollback:<srv>:<net>:#you` instead of `:#target`, and
`GET /api/channels/:net/:target/messages` returned empty.

**Invariant (must never regress):**
- For `PRIVMSG`/`NOTICE` where `params[0]` is not `#[&+!`, the buffer
  is the *counterparty*: `incoming → nick`, `outgoing echo (nick==sessionNick) → params[0]`.
- `connection.d:processLine` rewrites `event.channel` for `nick==sessionNick`
  before `queryBuffers` and `bufferManager` see it (see fix 2026-08-08).
- `queryBuffers` must track both directions (not `channel.length==0`).
- `parser.d` must not be the sole authority for DM channel — the
  session-aware fix in `connection.d` is authoritative.

**Test:** `e2e/chat-history-persist.spec.js` — sends DM to `Zodiac` on
`IRC Fiber`, asserts ` [role="log"]` contains it, reloads, asserts again.
Also covers channel `#ircfiber`. This is the regression gate.
## Deploy book pre-flight validation

The SigNoz role runs a **local ClickHouse config validator** before touching any host. It catches the class of bug that puts `signoz-clickhouse` into a restart loop on the live server (e.g. `background_pool_size * background_merges_mutations_concurrency_ratio < 20` default mutations free entries, or `< 25` for the partition-optimizer default). The OVH server hit this in June 2026 and the bad config took 30+ minutes to surface as a 728 MB `err.log` filling the writable layer.

Run **before** touching the OVH server when changing `deploy/roles/signoz/files/clickhouse-server-overrides.xml`:

```bash
# Validate the current production-equivalent config locally
./deploy/test/signoz-config/test-clickhouse-config.sh

# Run the regression suite against known-bad fixtures
./deploy/test/signoz-config/test-clickhouse-config-regressions.sh
```

The same validator is embedded as a preflight task in the `logging` role, so `ansible-playbook playbooks/logging.yml` aborts before any docker commands run on the host if the config is bad. Pass `--check` to skip the validator in a dry run. See `deploy/test/signoz-config/README.md` for the full rationale and what's tested.

---

# IRC Fiber — Deploy Architecture

Local dev is on Apple Silicon (ARM64). The production server `vps-efb4b52d` (203.0.113.10) is **x86_64**. **Never** compile D binaries locally and SCP them — they produce `exec format error` on the server.
Always build via the **remote BuildKit** (docker build on the server) or use `make update` which handles this automatically. The only exception is frontend dist assets (`public/dist/`) which are platform-independent JS/CSS/HTML and can be pushed directly via the SSH tar pipe in the Makefile.

```bash
# Correct: builds on the remote server
make update                        # full deploy (frontend + binaries, hard restart — see Engine Lifecycle above)
# (handoff removed 2026-08-08 — use hard restart via docker restart / make update)

# WRONG: local binary won't run on x86_64
scp irc-fiber deploy@server:/tmp/  # ← do not do this
```

## Deploy flow (hard restart)

`deploy-update.yml` builds the binary INSIDE a Docker container on the remote server using BuildKit:
1. Rsync local source → `/opt/ircfiber-src/` on remote
2. `docker build --target builder` — compiles D code via dub + LDC
3. Extracts binary from builder image
4. `docker cp` into running gateway container + restart
5. Engine hard restart — brief IRC disconnect, auto-reconnect via backoff (no handoff)

Key issue: `rsync delete: false` (now fixed to `delete: true`) allowed stale source files like `source/ircfiber/web/admin.d` to persist on the remote after the admin code was refactored into the `admin/` package directory. This caused `dub build` to fail with "package name conflicts with module name" — the error was hidden by `|| true` in the Containerfile's RUN command.

## Build cache invalidation

The Containerfile has two caching layers, both of which silently swallow code changes if not invalidated:

1. **Docker layer cache.** A bare `--build-arg CACHE_BUST=$(date +%s)` is **not enough** to invalidate a `COPY source/ ./source/` layer — BuildKit keys COPY layers by source-directory contents, not by build args. The Containerfile works around this with a heredoc sentinel (`COPY <<EOF ./source/.cache_bust_$CACHE_BUST\nbust=$CACHE_BUST\nEOF`) so the source tree's bytes change with `CACHE_BUST`. The next `COPY source/` is therefore invalidated.
2. **dub's incremental compile cache** (`/build/.dub`, mounted via `--mount=type=cache,sharing=locked`). Even if the COPY layer is fresh, LDC silently skips changed `.d` files when its module cache is warm. The Containerfile wipes `/build/.dub` when `CACHE_BUST` is non-default.

**Always pass `--build-arg CACHE_BUST=$(date +%s)`** when rebuilding locally after a code change. Without it, you can edit `source/ircfiber/irc/connection.d`, push the change, watch the engine restart cleanly, and STILL see the old behaviour — the build cache hides it.

This bite the author of the 432/433 nick-revert fix: the in-place mutation and dedup changes landed and worked, but the synthetic revert-event code was missing from the binary for ~20 minutes of debugging because the layer cache skipped recompilation. Symptom was `grep -ac 'Mirror the 433' /app/irc-fiber-engine` returning `0` on a freshly built image.

## Admin SPA deployment

Frontend assets (`public/dist/admin.html`, `assets/*`) are **baked into the
gateway image** at build time (`Containerfile` `COPY public/ ./public/` and
`COPY --from=builder-backend /build/views /app/views`). Two deploy paths exist:

| Command | What it does | IRC disconnect? | Survives `docker rm -f`? |
|---|---|---|---|
| `make update-assets` | `frontend` build + `docker exec tar` into running `ircfiber-gateway` (`/app/public`, `/app/views/index.dt`) — **ephemeral** | No | **No** — writable layer discarded on `docker rm` / `docker compose up --force-recreate` / host reboot. Use for quick iteration only. |
| `make update-gateway` | `frontend` build + `rsync` to `/opt/ircfiber-src/public` on host + `docker build --target runtime-gateway` on host + `ansible-playbook playbooks/gateway.yml` recreates `ircfiber-gateway` via `community.docker.docker_container` (correct Tailscale env, `ircfiber_net` + `ircfiber_logging`) — **persistent** | No (engine untouched) | **Yes** — new image baked, survives recreate/reboot. |
| `make update` | Full rsync + BuildKit `builder` + `docker cp` binary into gateway **and** engine + hard restart both — full deploy | **Yes** (brief, auto-reconnect) | Yes |

**Gotcha 2026-08-09:** a frontend deploy via `make update-assets` + manual
`docker rm -f ircfiber-gateway && docker compose up -d --no-deps ircfiber-gateway`
wiped the `docker exec`-pushed `main-S6NCrGWT.js` (BLCKND/SUPERNETS) and left the
SPA 404. The compose container also used the wrong `MONGO_URL`
(`mongo:27017` vs Tailscale `198.51.100.1:27017`) and never became healthy.
`make update-assets` now also `rsync`s to `/opt/ircfiber-src/public` for
persistence, and `make update-gateway` was added as the correct persistent
gateway-only path (engine stays up — `ircfiber-engine-ovh` not restarted).

```bash
# Quick iteration (ephemeral, ~3s):
make update-assets

# Persistent gateway-only (survives recreate, engine untouched):
make update-gateway

# Full persistent (gateway + engine, hard restart):
make update
```

The `--no-xattrs` flag on the `update-assets` tar pipe prevents macOS
extended attributes from creating duplicate `file 2.ext` entries on Linux.

## Admin -> SigNoz logs integration

The admin SPA at `ircfiber.com/admin#/logs` is a **native Svelte panel** that talks to SigNoz through the existing Caddy reverse-proxy. A deep link to the Tailscale-only SigNoz listener is offered as a fallback for the features the native panel does not cover (saved views, pivots, anomalies).

### Architecture decision (Option D)

Two prior attempts to embed the SigNoz UI via iframe were abandoned:
- `7795a73 fix(deploy): proxy SigNoz API and asset paths from root`
- `287d089 fix(deploy): scope SigNoz static proxy to index-* bundles`

Root cause: SigNoz v0.130's combined-image React bundle bootstraps a session JWT via client-side state. A static `SIGNOZ-API-KEY` header that Caddy injects server-side cannot be replayed by the bundle. The bundle loads, `/api/v1/user` returns 401, and SigNoz renders the cloud-icon error page.

A Caddy-side login proxy (POST `/api/v2/sessions` per iframe load) was considered and rejected because: (a) it would leak the admin password into the Caddyfile env, (b) it would hit session rate-limits, (c) any SigNoz version bump could break the login API contract.

**Option D** (the shipped architecture) replaces the iframe with a native Svelte panel for the 95% case (filter, paginate, time range, severity, row expand) plus a fallback link to the tailnet listener for the 5% case (server-side saved views, pivots, anomalies). Full task graph, rejected options, and pre-mortem live in [`docs/plan/20260630-admin-signoz-logs-panel/plan.yaml`](docs/plan/20260630-admin-signoz-logs-panel/plan.yaml).

### File layout

| File | Purpose |
|---|---|
| `frontend/src/lib/signoz.ts` | REST + WS wrapper: `queryRange`, `services`, `fields`, `fieldValues`, `currentUser`, `wsUrl(orgId)`. No Svelte imports. |
| `frontend/src/admin/stores/logsStore.ts` | UI state store: `LogsState`, debounced `runQuery` (200ms trailing), `setQuery`/`setService`/`setSeverity`/`setTimeRange`, `resetFilters`, `toggleExpandedRow`. |
| `frontend/src/admin/stores/logsLiveTail.ts` | WS reconnect with exponential backoff (1s to 30s cap, +/-20% jitter, 10-attempt cap). 5-state status machine: `idle` / `connecting` / `open` / `reconnecting` / `closed`. |
| `frontend/src/admin/stores/savedViews.ts` | localStorage-backed SavedView persistence. Stable interface (`listViews` / `saveView` / `loadView` / `deleteView`) is the future contract for a SigNoz SavedView backend. |
| `frontend/src/admin/lib/signozUrl.ts` | `TAILNET_SIGNOZ_URL` + `TAILNET_SIGNOZ_LOGS_URL` constants. Single source of truth for the tailnet listener IP. |
| `frontend/src/admin/components/logs/LogsToolbar.svelte` | Query bar + service multi-select + severity chips + time picker + live toggle + copy-as-cURL. |
| `frontend/src/admin/components/logs/LogRow.svelte` | One row (32px fixed height, severity chip, trace link). |
| `frontend/src/admin/components/logs/LogTable.svelte` | Offset virtualization (20-row overscan) + scroll restoration. Fixed row-height invariant. |
| `frontend/src/admin/components/logs/JsonDrawer.svelte` | Overlay JSON viewer (absolutely-positioned, anchored to clicked row). NOT inline expansion -- preserves LogTable's row-height invariant. Dismisses on Esc / backdrop / X. |
| `frontend/src/admin/components/logs/FilterCheatsheet.svelte` | `?` opens, `Esc` closes. Lists every supported filter field with examples. |
| `frontend/src/admin/pages/Logs.svelte` | Page composition: header + tailnet-fallback strip + view dropdown + `<LogsToolbar>` + state machine (skeleton / error / empty / table) + `<JsonDrawer>` + `<FilterCheatsheet>`. |

### Dev proxy (Vite)

`frontend/vite.config.ts` proxies SigNoz paths directly to a configurable `VITE_SIGNOZ_URL` (default `http://127.0.0.1:8080`, the host port mapped from docker-compose's `signoz` service). The SigNoz rules MUST come BEFORE the catch-all `/api` rule that targets the IRC Fiber gateway -- the gateway does not speak SigNoz protocol.

| Proxy rule | Target | WS |
|---|---|---|
| `/api/v1/` through `/api/v5/` | `VITE_SIGNOZ_URL` | no |
| `/signoz/` | `VITE_SIGNOZ_URL` | yes (`ws:true`) |

Override at run time:
```bash
VITE_SIGNOZ_URL=http://100.126.197.92:3003 npm run dev:local
```

If `VITE_SIGNOZ_URL` is unset and no local SigNoz is running, the panel renders a clear empty state ("SigNoz URL not configured") rather than failing silently.

### Caddy (prod)

`deploy/roles/caddy/templates/Caddyfile.j2` is unchanged from the prior proxy setup:
- `/api/v1/` through `/api/v5/` -> `signoz-signoz:8080` with `header_up SIGNOZ-API-KEY "{$SIGNOZ_API_KEY}"`
- `/signoz/ws/logs/*` -> `signoz-signoz:8080` with `flush_interval -1` for live-tail WS upgrades (dedicated `handle_path` block, separate from the document tree so the WS upgrade cannot be intercepted by SigNoz's SPA shell)
- `/signoz/*` and `/signoz` document tree -> `signoz-signoz:8080` (kept so a future fallback link routed through Caddy resolves; not used by the native panel)
- `@signoz_static` matcher scopes `/assets/index-*` and `/css/*` to SigNoz hashed bundles so admin SPA assets are not shadowed

If `/etc/ircfiber/signoz-mcp/.api_key` is missing, the entire `{% if caddy_signoz_api_key %}` block in `Caddyfile.j2` is skipped (no startup error, just no proxy) -- re-run the `signoz_mcp` + `caddy` roles to enable.

## Known issues

### MCP server DNS resolution (`signoz-signoz` vs `ircfiber-signoz`)

The `docker-compose.signoz-mcp.yml.j2` template sets `SIGNOZ_URL=http://signoz-signoz:8080`, but the SigNoz container is named `ircfiber-signoz` on the `ircfiber_logging` network. Docker DNS returns `SERVFAIL` for `signoz-signoz`. The correct hostname is `ircfiber-signoz`. The ansible template at `deploy/roles/signoz_mcp/templates/docker-compose.signoz-mcp.yml.j2` has been fixed.

### Distroless healthchecks

Both the MCP server (`signoz/signoz-mcp-server`) and the ingester (`signoz/signoz-otel-collector`) use distroless base images — no shell, `wget`, or `curl`. Healthchecks using these tools report `unhealthy` forever in `docker ps`. The correct fix is `healthcheck: disable: true` with `restart: unless-stopped` for process crash recovery. See:
- `deploy/roles/signoz_mcp/templates/docker-compose.signoz-mcp.yml.j2`
- `deploy/roles/logging/templates/docker-compose.logging.yml.j2` (signoz-ingester)
- `deploy/roles/signoz_bridge/tasks/main.yml` (otel-bridge)

The `signoz/signoz-otel-collector` binary is `/signoz-otel-collector` (not `/otelcol-contrib`). The `validate` subcommand does not exist in v0.144.5 — `signoz-otel-collector --help` only shows `help` and `migrate` subcommands. Using it for healthchecks fails silently.

### Ingester image mismatch (template vs deployment)

The logging role's `docker-compose.logging.yml.j2` template historically defaulted to
`otel/opentelemetry-collector-contrib:0.120.0` for the `signoz-ingester`, but the
actual running container was `signoz/signoz-otel-collector:v0.144.5`. These are
different images — the upstream `otel/opentelemetry-collector-contrib` does not
bundle the ClickHouse exporter that SigNoz requires. The fix pins the default to
`signoz/signoz-otel-collector:{{ signoz_ingester_version }}` in
`deploy/roles/logging/defaults/main.yml`.

The bridge collector (`ircfiber-otel-collector`) correctly uses the upstream
image since it only forwards OTLP and does not write to ClickHouse.

### SigNoz services detail page returns 500

The `/services/:name` page in SigNoz v0.131.1 fails with "Request failed with status code 500"
because the individual service detail API endpoint (`/api/v1/services/:name`) returns the SPA HTML
instead of JSON. The services LIST page and all other SigNoz features (logs, traces, dashboards)
work correctly. This is a SigNoz v0.131.1 backend bug — upgrading to a newer version may fix it.

### orgId provisioning (stale default UUID)

The `signoz_mcp` role's admin login task relied on a hardcoded default UUID for
`orgId` (`019f1235-79b1-787f-b4a9-370824295f2f`). If the SigNoz SQLite DB was
ever recreated, the org ID would change and the playbook would fail with
`user_not_found`. Fixed by adding a runtime discovery task that reads the org ID
from the running container's `signoz.db` before provisioning the API key.

### Tailnet fallback link

`Logs.svelte` renders an "Open SigNoz" link in the page header pointing to `TAILNET_SIGNOZ_LOGS_URL` (e.g. `http://100.126.197.92:3003/logs`). This is the deep link into the Tailscale-only SigNoz listener for features the native panel intentionally does not implement in v1: server-side saved views, pivots, anomaly overlays, query-builder joins. The IP literal lives only in `frontend/src/admin/lib/signozUrl.ts` -- do not hard-code it elsewhere.

### Saved views (localStorage)

`frontend/src/admin/stores/savedViews.ts` persists user-named query snapshots to `localStorage` under `ircfiber:admin:logs:views`. On quota error, the store prunes to the most-recent 50 views and surfaces a toast warning. The snapshot shape (`query`, `services`, `severities`, `timeRange`) deliberately matches `logsStore.ts`'s `LogsState` minus volatile fields so the future SigNoz SavedView backend swap keeps the public API stable.

### Rollout

```bash
# 1. Ensure signoz_mcp role has run so the API key file exists
ansible-playbook playbooks/signoz_mcp.yml -e vault_signoz_admin_password=...

# 2. Re-run the caddy role to render the route + pick up the key
ansible-playbook playbooks/site.yml --tags caddy

# 3. Build + ship the frontend (make update bundles on the remote)
make update

# 4. Verify REST
curl -fsS https://ircfiber.com/api/v1/services -H 'X-Requested-With: smoke' | head
# Should return JSON with the "IRC Fiber" service inventory
```

WS upgrade smoke test (should return `101 Switching Protocols`; `200` means the dedicated `/signoz/ws/logs/*` `handle_path` block in `Caddyfile.j2` is missing):
```bash
curl -i --http1.1 \
  -H 'Connection: Upgrade' \
  -H 'Upgrade: websocket' \
  -H 'Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==' \
  -H 'Sec-WebSocket-Version: 13' \
  https://ircfiber.com/signoz/ws/logs/v5/default
```

### Plan reference

Full task graph (18 tasks across 4 waves): [`docs/plan/20260630-admin-signoz-logs-panel/plan.yaml`](docs/plan/20260630-admin-signoz-logs-panel/plan.yaml). Wave 1 covers `signoz.ts` + `logsStore` + `savedViews` + Vite dev proxy + `signozUrl.ts`. Wave 2 covers the Svelte components (`LogRow`, `LogTable`, `JsonDrawer`, `LogsToolbar`, `FilterCheatsheet`, `Logs.svelte` rewrite). Wave 3 covers the WS preflight + `logsLiveTail` + Caddy WS audit. Wave 4 covers keyboard shortcuts, copy-as-cURL, empty/error states, and this `AGENTS.md` update.

## Engine priority and assignment architecture

`assignNetwork()` in `source/ircfiber/irc/registry.d` selects a server for new networks. Fixed from pure least-loaded to priority-aware:
- Higher `priority` wins
- `fallbackOnly` servers excluded unless no other healthy servers exist
- Tiebreaker: fewest assigned networks

Engine config overrides (`priority`, `fallbackOnly`, `maxConnections`) are stored in `irc:engine:config:<serverId>` in Redis. The engine reads them at boot and every 10s in the heartbeat loop. However, the heartbeat was only writing `lastHeartbeat`/`isHealthy` — the `data` field (containing priority etc.) was never synced to Redis. Fixed by adding `syncServerState()` which persists the full server record every heartbeat cycle.

Existing network assignments are sticky — they stay on the current server until explicitly reassigned (via admin API `/api/admin/servers/:id/reassign`) or the server dies. `healthCheckAll()` now has a Phase 3 that reconciles orphaned assignments: networks in `irc:assignments` that don't appear in the assigned server's `assignedNetworks` list are reassigned to a proper home.

## Server reboot behavior

Engine config overrides (`priority`, `fallbackOnly`, `maxConnections`) are stored in Redis keys `irc:engine:config:<serverId>`. Redis persists to disk, so these survive reboots. On server restart (all containers start simultaneously):

1. Redis/Mongo start first (host network mode)
2. Gateway + Engine containers start on `ircfiber_net` bridge network
3. Each engine reads its assigned networks from `irc:assignments` (Redis hash)
4. **Key fix**: During boot, if a lower-priority engine sees networks assigned to a higher-priority engine (but that engine hasn't heartbeated yet), it **defers reclaim** instead of stealing them (`bootstrap.d:216-224`). This prevents a lower-priority engine from taking over a higher-priority engine's networks during a full reboot.

All containers use `restart_policy: unless-stopped`, so `docker restart` on the host recovers everything automatically.

---

---

# IRC Fiber — Engine Janitor

The `EngineJanitor` (in `source/ircfiber/irc/engine_janitor.d`) prevents orphan-engine garbage from accumulating in Redis after a crash. Without it, dead engines leave `irc:state:<id>:*`, `scrollback:<id>:*`, and `dedup:<id>:*` keys forever — the gateway keeps routing to a dead server while the frontend renders a frozen ghost of the channel.

## How it works

Four layers run automatically in **every** gateway and engine process:

1. **TTL auto-expiry** — every per-engine state key gets `EXPIRE 600s`. The engine heartbeat bumps TTL every 10 s. A dead engine's state self-evicts within 10 min, even if no janitor ever runs.
2. **Distributed janitor** — every process tries to acquire `irc:janitor:lock` via `SET NX EX 30`. Holder runs the reap; losers yield. Lua scripts make the reap atomic against late heartbeats.
3. **Bootstrap purge** — on engine boot (skipping handoff), `purgeLocalServerNamespace(serverId)` SCANs+UNLINKs `*:<serverId>:*` so reusing a `serverId` after a crash doesn't carry garbage across epochs.
4. **Frontend staleness** — `lastSeenAt` per network, `isNetworkStale()` helper, grey "● stale" pill in the sidebar. Buffer cache in localStorage uses a 24 h TTL guard.

# IRC Fiber — User "Clear backlog" deletes server log history

The chat sidebar's right-click "Clear backlog" (server log and per-channel) actually scrubs the Redis scrollback now — it is not just a client-side filter.

## Behavior

| Layer | Effect |
|---|---|
| `ircfiber.storage.buffer.BufferManager.clearBuffer(serverId, networkId, buffer)` | `DEL` of `scrollback:<srv>:<net>:<buf>` and its paired `dedup:<srv>:<net>:<buf>` SET. Namespaced for decentralized mode; legacy single-arg overload for single-server mode. |
| `POST /api/networks/:id/buffers/clear` (body `{"buffer":"<name>"}`) | Auth-gated + owner-checked (`networkRepo.findByIdWithUser` against `req.context["user"]`). Looks up the assigned server via `ServerRegistry.getServerForNetwork` and dispatches to either the namespaced or legacy `clearBuffer` overload. Returns `{status:"cleared", buffer, serverId}`. |
| `frontend/src/components/{Server,Channel}ContextMenu.svelte` `clearBacklog` | `setClearedAt(...)` for immediate UI hide, then `api.clearBacklog(...)` to scrub Redis. API failures log to console but still apply the local filter (graceful degradation). |
| `frontend/src/lib/slashCommands.ts` `/clear` | Same: `setClearedAt` + API call, so typing `/clear` in a server tab actually deletes the server log. |

The localStorage `clearedAt` flag is still required because the server side has no realtime "I just cleared my buffer" message back to the open WebSocket — the local filter hides cards on the next render, while the API call scrubs Redis so a page refresh or new tab gets an empty history (rather than the cleared messages re-appearing from `CHATHISTORY`/snapshots).

## Environment knobs

| Env var | Default | Range | Effect |
|---|---|---|---|
| `IRCFIBER_STATE_TTL` | 600 | 60–86400 | TTL on per-engine state keys (seconds) |
| `IRCFIBER_JANITOR_INTERVAL` | 60 | 5–3600 | Seconds between janitor cycles |
| `IRCFIBER_JANITOR_LOCK_TTL` | 30 | 5–300 | Distributed lock TTL |
| `IRCFIBER_BOOTSTRAP_PURGE` | 1 | 0/1 | Disable bootstrap-time namespace purge |
| `JSMIGRATE_DRY_RUN` | 1 | 0/1 | Migration tool: dry-run vs. apply |
| `IRCFIBER_MIGRATE_TTL` | 600 | 60–86400 | Migration tool TTL to apply |

Invalid values fall back to defaults with a `WARN:` line at startup.

## Build targets

```bash
# Run all 9 janitor tests
./run-janitor-tests.sh
# or
make janitor-tests

# Build the migration tool + run dry-run
make janitor-migrate

# Manually trigger / observe (admin session required)
make janitor-status
make janitor-audit
make janitor-cycle
make janitor-reap SERVER=testengine1
```

## Admin endpoints (gated behind admin session)

| Endpoint | Purpose |
|---|---|
| `GET  /api/admin/janitor/status` | Lock holder, actor, totals, last cycle |
| `GET  /api/admin/janitor/events?limit=100` | Recent audit events (most-recent-first) |
| `POST /api/admin/janitor/cycle` | Force one reap cycle right now |
| `POST /api/admin/janitor/reap/<serverId>` | Manually purge one server's namespace |

Audit events look like:
```json
{"ts":1782703502123,"kind":"engine_reap","serverId":"testengine1","actor":"pid:19490:host=zodiac-mbp","reason":"lease_expired","keysDeleted":42}
```
Stored in the `irc:janitor:events` Redis LIST (capped at 1000 via `LTRIM`).

## Test binaries

| Binary | Config | Tests |
|---|---|---|
| `janitor-test` | `dub build --config=janitor-test` | purge idempotency, basic reap |
| `janitor-lock-test` | `dub build --config=janitor-lock-test` | manualReap, lock mutual exclusion |
| `janitor-safety-test` | `dub build --config=janitor-safety-test` | getStatus, getRecentEvents, TTL bump |

`./run-janitor-tests.sh` builds all three and aggregates `[PASS]/[FAIL]/[SKIP]`.

## Deploy / rollout

```bash
# 1. (Optional) Backfill TTL on existing keys locally — already done by `make update` automatically
JSMIGRATE_DRY_RUN=1 ./janitor-migrate
JSMIGRATE_DRY_RUN=0 ./janitor-migrate

# 2. Deploy via your normal pipeline:
make update        # full deploy (engine + frontend + hard restart + janitor-migrate + verification)
# (handoff removed 2026-08-08 — see Engine Lifecycle above)
make gateway-restart  # gateway-only reload

# Skip the migration step on a `make update`:
SKIP_MIGRATE=1 make update

# 3. Verify after deploy:
curl -s http://127.0.0.1:8090/api/admin/janitor/status
```

The migration step is **idempotent** — running it again is a no-op. When invoked through `make update`, the playbook:
1. Builds `janitor-migrate` cross-arch via BuildKit
2. Extracts to `/opt/ircfiber/bin/janitor-migrate` on the target
3. Waits 60 s for the new engine to register and start heartbeating
4. Runs `JSMIGRATE_DRY_RUN=1` (dry-run) and prints the result
5. Runs `JSMIGRATE_DRY_RUN=0` (apply) and prints the result
6. Waits one janitor cycle, then fetches `/api/admin/janitor/status` and prints it

Skipped automatically when `ircfiber_engine_id` is not defined (i.e. only the gateway is in scope).



# IRC Fiber — IRC Engine vs IRC Server Parity Tests

`tests/irc_parity/` holds end-to-end tests that drive the IRC Fiber engine
against real IRC servers (ngircd, UnrealIRCd + Anope) and a custom mock IRC,
then assert that the engine's stored state in Redis matches what the wire
protocol says. Use these to verify parity for IRC features (JOIN, NAMES, MODE,
kick, ban, services-style auto-op, etc.).

## Layout

- `tests/irc_parity/__init__.py` — `IrcClient` (minimal synchronous IRC
  client over raw TCP), `ParsedLine` (RFC 2812 line parser with IRCv3
  message-tag support), and `assert_user_prefix` / `wait_engine_snapshot_contains`
  helpers.
- `tests/irc_parity/test_irc_parity.py` — pytest scenarios. The first scenario
  verifies that a user auto-opped on JOIN by services is correctly recorded
  with the `@` prefix in the engine's `irc:state:<server>:<network>` Redis
  snapshot.
- `tests/irc_parity/fixtures/mock-irc-op/` — Dockerfile + server.py for a
  mock IRC server that simulates Anope/Chanserv auto-op on JOIN.

## Running

The parity tests are integration tests, so they require the docker-compose
stack to be running:

```bash
# Bring up redis, mongo, gateway, engine, and the IRC fixtures.
docker compose -f docker-compose.test.yml up -d redis mongo gateway engine mock-irc-op

# Port-forward mock-irc-op so the test runner (running on the docker host)
# can also reach it as 127.0.0.1:6667.
docker run -d --rm --name mock-irc-op \
  --network irc_fiber_irc_network -p 6667:6667 mock-irc-op:parity

pip3 install --break-system-packages pytest

# Run the parity tests
python3 -m pytest tests/irc_parity -v
```

By default the engine inside docker reaches the IRC server via the docker
service name (`mock-irc-op`). Override with `IRC_NETWORK_HOST_FOR_ENGINE` if
you point the engine at a different hostname.

## Adding a new parity scenario

```python
from tests.irc_parity import IrcClient, assert_user_prefix, wait_engine_snapshot_contains


def test_kick_removes_user_from_snapshot(scenario):
    # `scenario` fixture gives you a connected network with the engine
    # attached to the mock IRC server.
    ...

    # Wait up to 15s for the engine's snapshot to reflect the change.
    snapshot = wait_engine_snapshot_contains(
        redis_container="irc_fiber_redis",
        server_id="debugengine1",
        network_id=scenario["network_id"],
        predicate=lambda s: scenario["username"] not in (s or ""),
        timeout=15.0,
    )
```

The engine writes a fresh snapshot every 10 s, so predicates that depend
on the snapshot must allow up to ~12 s of latency.

# IRC Fiber — Member List Operator Status Fix

Fix for: "It does not show me as having Operator status in the members list
when I join a channel. The members list does not update my Operator status in
real-time, nor does it update if I hard refresh."

## Root cause

Three independent bugs combined to drop the IRC prefix char (`@`, `+`, `%`,
etc.) from users' nicks stored in the member list:

1. **Frontend MODE handler was parsing the wrong param.** IRCv3 wires
   `MODE #chan +o alice` as `params = ["#chan", "+o", "alice"]`, but the
   handler read `params[0]` as the mode string — which is the channel name.
   This corrupted the prefix update path on every channel MODE event.

2. **`normalizeUser` stripped the prefix on snapshot round-trip.** When
   the engine sent `users: ["@alice"]` over the WebSocket, the handler
   converted it to `{ nick: "alice", prefix: "@", ... }` and the
   `<span class="member-nick">{member.nick}</span>` template then displayed
   the bare nick. Hard refresh = fresh sync = bug on every reload.

3. **Engine `channelUsers` dedup was exact-match.** A race between the
   self-JOIN handler (which added `user` bare) and the server's 353
   (which arrived as `@user` prefixed) left two entries in
   `channelUsers`. The frontend's `updateNetworkFromSync` then deduped by
   stripped nick and kept the FIRST one — the bare entry from JOIN —
   dropping the op prefix.

## Fixes

- `frontend/src/stores/ircStore.svelte.ts`
  - `updateChannelUsers` MODE branch now reads `params[0]` as the target
    and `params[1]` as the mode string, with a guard so a user-mode
    `MODE nick :+i` is a no-op for the channel user list.
  - 353 handler now does **in-place promotion** in place of the
    skip-if-exists path: when a NAMES entry's bare nick already exists
    in the buffer, the existing entry's `nick` is rewritten to the
    prefixed form and its `prefix` / `category` are updated.
  - `normalizeUser` (the snapshot-path converter) now stores `nick: user`
    (preserving the IRC prefix char) instead of `nick: bareNick`. The
    `prefix` and `category` fields are still set so sorting and the
    ops/voiced/halfop category grouping keep working.
  - `MemberList.svelte` renders `{member.nick}` so users with a prefix
    display their `@` / `+` / `%` / `&` / `~` / `!` indicator.

- `source/ircfiber/irc/connection.d`
  - JOIN handler now does stripped-nick dedup (was exact-match) so a
    prior prefixed entry is not shadowed.
  - 353 handler does stripped-nick dedup with in-place promotion to
    the prefixed form, so a services-granted op survives the snapshot.
  - MODE handler accepts `O` (IRC Operator) in addition to `qaohv`.

## Tests

- `frontend/src/stores/ircStore.mode-bug.test.ts` — 4 regression tests
  for the MODE-handler param bug.
- `tests/irc_parity/test_irc_parity.py` — end-to-end test that drives
  the engine against a mock IRC server auto-opping joiners and asserts
  the engine's `irc:state:<server>:<network>` snapshot contains `@user`
  (single entry, no bare duplicate).
- All existing unit tests still pass: 604 client + 379 lib vitest tests.

# IRC Parity Testing — Findings and Bugs

`tests/irc_parity/` holds end-to-end tests that drive the IRC Fiber engine
against the in-repo docker-compose stack (mock-irc-op, ircd-test,
unreal_sasl + Anope, redis, mongo, gateway, engine) and verify the engine's
stored state matches the wire protocol.

## Mock-irc-op (configurable synthetic IRCd)

The mock-irc-op fixture (`tests/irc_parity/fixtures/mock-irc-op/`) is a
Python-based IRCd that simulates Anope/Chanserv-style auto-op on JOIN.
The mock IRC supports the full lifecycle: NICK, USER, JOIN, 353 (with
NAMES), 366, PART, KICK, NICK change, TOPIC, MODE (channel and user),
WHOIS (311), 433 (NICKNAMEINUSE), PING/PONG, QUIT, PRIVMSG.

## Tests

`tests/irc_parity/test_irc_parity.py` has 10 scenarios, 9 passing:

- `TestMockIrcOperator::test_user_appears_with_prefix_after_join` — PASS
  Mock IRC auto-ops joiner; engine shows @user in snapshot.
- `TestKickRemovesUser::test_kick_removes_user` — PASS
  A 2nd user kicks the engine user; engine removes them from the snapshot.
- `TestPartRemovesUser::test_part_removes_user` — PASS
  Engine PARTs; engine removes from the snapshot.
- `TestModeChange::test_deop_via_mode_minus_o` — PASS
  A 2nd user issues MODE -o on the engine user; engine updates snapshot.
- `TestModeChange::test_voice_via_mode_plus_v` — PASS
  MODE +v sets the engine user's voice prefix; engine updates snapshot.
- `TestModeChange::test_multi_target_mode` — **FAIL** (bug, see below)
- `TestTopic::test_topic_set_and_seen` — PASS
  A 2nd user sets a channel topic; engine captures it in `topics`.
- `TestNickChange::test_other_user_nick_change_visible_in_snapshot` — PASS
  A 2nd user changes their nick; engine updates the snapshot with the new
  nick.
- `TestMultipleUsers::test_multiple_users_in_roster` — PASS
  Multiple users in the same channel all appear in the engine's roster.
- `TestNickInUse::test_engine_handles_433_gracefully` — PASS (trivially;
  no negative scenario exercised).

## Known bugs discovered

### BUG #1: Engine doesn't track the status of users who join AFTER it

When a user joins a channel where the engine is already present, the
engine only sees the JOIN message (no NAMES list, since 353 is only sent
to the joining user). The engine's JOIN handler at
`source/ircfiber/irc/connection.d:2484-2522` stores the user as bare (no
prefix):

```d
} else {
    channelUsers[chan] ~= event.nick;  // bare nick, no prefix
    ...
}
```

When the server later issues a multi-target MODE like `MODE #chan +vv user1 user2`,
the MODE handler at `source/ircfiber/irc/connection.d:2904` only updates the
user1 entry (which has a prefix from the engine's own 353); user2 is
stored as bare and the MODE doesn't change it.

**Reproduction**: `tests/irc_parity/test_irc_parity.py::TestModeChange::test_multi_target_mode`
The snapshot after the test shows `+engine_user, mod, helper` — the helper
should be `+helper` but stays bare.

**Fix ideas** (none implemented yet):
1. Issue a `WHO %channel` after a JOIN broadcast to discover each user's
   status, and re-promote the channel roster entry with the discovered
   prefix.
2. Issue `NAMES #chan` periodically to refresh the roster.
3. Parse IRCv3 `extended-monitor` or `account-notify` to track which
   nicks are services-identified, but those don't carry mode prefixes.
4. Conservatively: when a `MODE +X` is processed and the target user is
   stored bare, mark the target user with a placeholder so the snapshot
   doesn't lie about who has what mode.

### BUG #2 (related): Engine's MODE handler runs before the engine sees the
   joining user's status

Even with bug #1 fixed, the race is: the helper sends JOIN → mock IRC
broadcasts the helper's JOIN to the engine → engine adds `helper` bare →
mod sends MODE +vv engine helper → engine processes MODE.

If the helper's 353 (with prefix) hasn't yet arrived at the engine when
the MODE is processed, the engine can't apply the prefix. The
`test_voice_via_mode_plus_v` test works only because mod joined BEFORE
the helper and was in the roster when the MODE was processed.

## Setup

```bash
docker compose -f docker-compose.test.yml up -d redis mongo gateway engine ircd-test mock-irc-op

# Or start the existing stack (unreal_sasl + Anope) and use it instead of
# ircd-test / mock-irc-op:
docker run --rm -d --name mock-irc-op --network irc_fiber_irc_network -p 6667:6667 \
  $(docker build -q tests/irc_parity/fixtures/mock-irc-op)

docker run --rm -d --network irc_fiber_irc_network --name irc_fiber_engine \
  -e IRCFIBER_REDIS_URL=redis://irc_fiber_redis:6379/0 \
  -e IRCFIBER_MONGO_URL=mongodb://irc_fiber_mongo:27017/ircfiber \
  -e IRCFIBER_LOG_LEVEL=debug \
  -e IRCFIBER_SERVER_ID=debugengine1 \
  irc-fiber:latest /app/irc-fiber-engine

docker run -d --network irc_fiber_irc_network --name irc_fiber_gateway -p 8090:8090 \
  -e IRCFIBER_REDIS_URL=redis://irc_fiber_redis:6379/0 \
  -e IRCFIBER_MONGO_URL=mongodb://irc_fiber_mongo:27017/ircfiber \
  irc-fiber:latest /app/irc-fiber

# Deploy the latest frontend
docker cp public/dist/. irc_fiber_gateway:/app/public/dist/

pip3 install --break-system-packages pytest

# Run the parity tests
python3 -m pytest tests/irc_parity/test_irc_parity.py -v
```

## Using the real unreal_sasl + Anope stack

The unreal_sasl container has Anope services linked. To exercise the
auto-op-on-JOIN scenario against real services, register a nick with
NickServ (no email confirmation needed), identify, register a channel,
give yourself SOP, and have the engine connect with SASL PLAIN as that
same nick. The engine's network config requires `sasl: "plain"`,
`saslUsername: "<nick>"`, `saslPassword: "<password>"`.

A reference test for this flow is sketched in
`tests/irc_parity/test_real_services.py` (not currently runnable in
the in-repo docker stack because the engine's SASL handshake with
unreal_sasl needed a different password and the engine's connection
flickered under repeated test runs; this is a work-in-progress).

# IRC Fiber — Distroless OTel collector healthcheck pattern

The `ircfiber-signoz-ingester` (and the bridge `ircfiber-otel-collector`)
both use `otel/opentelemetry-collector-contrib`, which is a **distroless**
image: no shell, no wget, no nc, no `/bin/sh`. Docker compose v2 healthchecks
only support `CMD`, `CMD-SHELL`, and `NONE` — and `CMD-SHELL` rewrites to
`/bin/sh -c …` internally, which immediately fails on a distroless image
(`exec: /bin/sh: no such file`), leaving the container marked unhealthy
forever even when the collector is happily accepting OTLP.

Right pattern for a distroless collector healthcheck:

```yaml
healthcheck:
  test: ["CMD", "/otelcol-contrib", "validate", "--config=/etc/otel-collector-config.yaml"]
  interval: 60s
  timeout: 5s
  retries: 3
  start_period: 30s
```

This probes **config validity**, not liveness — `validate` only checks that
the YAML parses. That's actually what we want for "container is broken":
if the config is malformed, `validate` exits 1 and Docker marks the
container unhealthy (visible in `docker ps`). If the collector process
crashes mid-flight, `restart: unless-stopped` (via `x-logging-common` in
`docker-compose.logging.yml.j2`) brings it back; the bridge collector will
show `connection-refused` against OTLP if the listener is down, which is
the real liveness signal at the application layer.

Also: the `clickhouse` exporter in the OTel collector runs `CREATE DATABASE`
on startup to bootstrap the schema, so it crashes once if ClickHouse
isn't ready yet (typically ~5–15s after the container starts). Docker
`restart: unless-stopped` handles this in 1–2 retries — no `depends_on:
condition: service_healthy` needed, because that would require the
healthcheck above to be live (and we just said it can't be).

See `deploy/roles/logging/templates/docker-compose.logging.yml.j2` for
the deployed config.

## IRC Fiber — Observability

The IRC Fiber stack uses **SigNoz** as its single observability store for
logs, traces, and metrics. Grafana is retained as a cross-data-source
dashboard layer, configured to query SigNoz via the Infinity datasource
plugin (`yesoreyeram-infinity-datasource`) at `signoz-signoz:8080`.

### Architecture

```
┌─────────────────┐     OTLP HTTP      ┌──────────────┐
│  Fluent Bit     │ ──────────────────► │              │
│  (container     │     port 4318       │  signoz-     │
│   log tailer)   │                     │  ingester    │
└─────────────────┘                     │  (OTLP       │
                                        │   receiver)  │
┌─────────────────┐     OTLP HTTP      │              │
│  IRC Fiber      │ ──────────────────► │              │
│  Engine/Gateway │     port 4318       │              │
│  (D processes)  │                     └──────┬───────┘
└─────────────────┘                            │
                                     ┌─────────▼─────────┐
                                     │  signoz-query-     │
                                     │  service           │
                                     │  port 8080 (int)   │
                                     │  port 3301 (host)  │
                                     └──┬──────┬──────┬───┘
                                        │      │      │
                          ┌─────────────┘      │      └─────────────┐
                          ▼                    ▼                    ▼
                   ┌──────────┐        ┌────────────┐       ┌──────────────┐
                   │ ClickHouse│        │ SigNoz     │       │ Grafana      │
                   │ (storage) │        │ Frontend   │       │ (dashboards) │
                   └──────────┘        └────────────┘       └──────────────┘
```

**Data paths:**

| Signal | Source | Destination | Protocol |
|---|---|---|---|
| Logs | Fluent Bit (Docker log tailer) | signoz-ingester:4318 | OTLP HTTP |
| Logs (Caddy access) | Bridge otel-collector (filelog/caddy receiver) | signoz-ingester:4317 | OTLP gRPC |
| Traces | Engine/Gateway (D tracing.d) | signoz-ingester:4318 (local dev) or bridge (prod) | OTLP HTTP |
| Metrics | Bridge otel-collector (hostmetrics + docker_stats receivers) | signoz-ingester:4317 | OTLP gRPC |

In **production**, the bridge (`ircfiber-otel-collector`, deployed by the
`signoz_bridge` role) sits on both `ircfiber_net` and `ircfiber_logging`
networks, proxying OTLP from D services to signoz-ingester. In **local dev**
the engine/gateway write OTLP directly to `signoz-ingester:4318`.

### Port clarification

| Port | Service | Bind | Purpose |
|---|---|---|---|
| 3301 | signoz-query-service | host:3301 | SigNoz REST API + UI access (dev) |
| 8080 | signoz-query-service | container:8080 | Internal query-service API (no host map) |
| 4317 | signoz-ingester | container:4317 | OTLP gRPC intake (bridge export target) |
| 4318 | signoz-ingester | container:4318 | OTLP HTTP intake (Fluent Bit + engine) |
| 13133 | signoz-ingester | container:13133 | Health check endpoint |

### File layout

| File | Purpose |
|---|---|
| `deploy/roles/signoz_bridge/defaults/main.yml` | Bridge container defaults (image, ports, networks, resources) |
| `deploy/roles/signoz_bridge/tasks/main.yml` | Ansible tasks: network join, container create, healthcheck |
| `deploy/roles/signoz_bridge/templates/otel-collector-config.yaml.j2` | OTel collector config: OTLP receivers, hostmetrics, docker_stats, filelog/caddy, transform/newrelic, redaction, batch export |
| `deploy/roles/logging/templates/fluent-bit.conf.j2` | Production Fluent Bit config (Docker JSON log tail, engine_json parser, docker metadata enrichment, OTLP output) |
| `deploy/local/fluent-bit.conf` | Dev Fluent Bit config (minimal — no docker socket enrichment) |
| `deploy/roles/logging/defaults/main.yml` | Versions, container names, resource limits, alert gating |
| `deploy/roles/logging/tasks/main.yml` | Orchestration: network/volume creation, template rendering, compose deploy, healthchecks |
| `deploy/roles/logging/templates/docker-compose.logging.yml.j2` | SigNoz Foundry + Grafana docker-compose template (production) |
| `deploy/roles/logging/templates/grafana-datasources.yml.j2` | Grafana SigNoz datasource via Infinity plugin |
| `deploy/roles/logging/templates/grafana-dashboards.yml.j2` | Grafana dashboards provider config |
| `deploy/roles/logging/files/dashboards/` | 6 Grafana dashboard JSON definitions |
| `deploy/roles/signoz_alerts/files/alert_rules.yml` | SigNoz alert rules (7 host + container + service alerts) |
| `deploy/roles/logging/tasks/deploy-alerts.yml` | Ansible alert deployment (gated by `deploy_signoz_alerts`) |
| `deploy/roles/logging/tasks/cleanup-old-stack.yml` | Remove old Loki/Promtail/Tempo/otel-collector/Prometheus |

### Grafana

Repurposed from the old Loki+Tempo+Prometheus setup. Now uses **SigNoz**
as its sole provisioned datasource via the Infinity plugin:

```yaml
datasources:
  - name: SigNoz
    type: yesoreyeram-infinity-datasource
    url: http://signoz-signoz:8080
```

Provisioned dashboards (6):

| Dashboard | Focus |
|---|---|
| `container-health.json` | Docker container CPU/memory/restart counts |
| `irc-bugs-errors.json` | Error rate by service, top error messages |
| `irc-connection-lifecycle.json` | Connection events, disconnects, reconnects |
| `irc-distributed-traces.json` | Trace waterfall, span duration, service map |
| `irc-handoff.json` | Handoff duration, socket counts, TLS vs plain |
| `irc-protocol-events.json` | JOIN/PART/KICK/MODE event rates |

The `GF_INSTALL_PLUGINS` env var installs `yesoreyeram-infinity-datasource`
at Grafana boot.

### Local dev

Docker Compose at `deploy/local/docker-compose.yml` brings up 11 containers
on the `ircfiber_local` bridge (172.28.0.0/16):

```
redis, mongo, signoz-clickhouse, signoz-query-service, signoz-ingester,
signoz-frontend, signoz-alertmanager, fluent-bit, ircfiber-gateway,
ircfiber-engine, ircd
```

Makefile targets:

```bash
# Start
make local-dev-up           # docker compose up -d

# Smoke test (gateway health + SigNoz API + OTLP ingestion + Fluent Bit)
make local-dev-smoke

# Access points:
# - SigNoz UI/REST: http://localhost:3301
# - Gateway health: http://localhost:8090/health
# - Admin panel: http://localhost:5173 (via `npm run dev:local`)
# - IRC daemon: localhost:6667

# Stop
make local-dev-down        # preserves data volumes
make local-dev-down-clean  # wipes ClickHouse data too
```

See `deploy/local/README.md` for full instructions, prerequisites, and troubleshooting.

### Alert rules

14 Loki alert rules were migrated to SigNoz LOGS_BASED_ALERT rules
(gated under `deploy_signoz_alerts: true` in the logging role).

Rule definitions: `deploy/roles/logging/signoz-alerts.yml.j2`
Deployment: `deploy/roles/logging/tasks/deploy-alerts.yml`

| Rule | Filter | Threshold | Severity |
|---|---|---|---|
| IrcfiberTLSFailures | `attribute.event = 'tls_fail'` | >3 in 5m | warning |
| IrcfiberReconnectStorm | `attribute.event = 'reconnect_scheduled'` | >10 in 5m | warning |
| ... (14 total) | See signoz-alerts.yml.j2 for full table | | |

### Configuration & cleanup

The old Loki/Promtail/Tempo/Prometheus stack was removed in favor of
SigNoz + Fluent Bit. The opt-in cleanup task at
`deploy/roles/logging/tasks/cleanup-old-stack.yml` removes remaining
containers, volumes, and config directories.

### Plan reference

Full task graph (14 tasks across 4 waves):
[`docs/plan/20260701-signoz-unified-observability-and-local-docker/plan.yaml`](docs/plan/20260701-signoz-unified-observability-and-local-docker/plan.yaml)

# IRC Fiber — Orphan-connection delete (admin Servers table)

The admin `#/servers` Network Assignments table used to expose only
"Disconnect / Reassign / Remove". None of those removed an orphaned
empty-string entry that could appear in an engine's `assignedNetworks`
array — the gateway showed it as a ghost row with no name, no host, no
owner, and no useful buttons. This was the user-visible symptom of a
stale engine write: a `""` networkId inserted into `irc:server:<sid>`'s
`data.assignedNetworks` array survived every heartbeat because the
per-engine mirror (`irc:server-assignments:<sid>`) was clean and so
the engine's canonical reconciliation couldn't see anything to
disconnect.

The fix is three layers — the API gets a host-less full-delete path,
the SPA gets a Delete button that demands the operator type the
network label back, and the engine self-heals so a fresh orphan can
never come back.

## Architecture

```
Engine (D)                                Frontend (TS)
──────────────────────────                 ────────────────────────
bootstrap.d heartbeat:                     Servers.svelte table:
  syncServerState(localServer)               Delete button (per row)
    ↓                                       ↓
  getCanonicalNetworks()                     api.post(
    ↓                                         /api/admin/servers/
  localServer.assignedNetworks = canonical     assignments/<id>/delete,
    ↓                                         confirm + typed-label
  filter!(n => n.length > 0)  ← self-heal      prompt, then submit
    ↓
  publishServerAssignments(mirror)
    ↓
  syncServerState(localServer)  ← 2nd write
                                        api.d → apiAssignmentDelete
                                          ↓
                                        deleteNetworkCore:
                                          • lpush removeNetwork
                                            control to engine
                                          • Mongo deleteById
                                          • Redis: state, fail, ban
                                          • HDEL irc:assignments
                                          • scrub server record +
                                            per-engine mirror
                                          (allowEmpty=true walks
                                           every server for orphans)
```

Files:

| File | Purpose |
|---|---|
| `source/ircfiber/web/admin/api.d` | `deleteNetworkCore()` shared by form + JSON paths. `apiAssignmentDelete` is the new SPA-facing endpoint; `apiHostDeleteNetwork` now delegates to the core. `allowEmpty=true` lets the SPA scrub ghost rows that have no Mongo record. |
| `source/ircfiber/web/admin/package.d` | Registers `POST /api/admin/servers/assignments/:networkId/delete` next to the existing `/remove` route. |
| `source/ircfiber/irc/registry.d` | `assignNetwork("")` now refuses with a warning (the entry path that produced the original ghost row). `publishServerAssignments` filters empty ids as a second line of defence. |
| `source/ircfiber/engine/bootstrap.d` | Heartbeat self-heal: filter empty ids out of `localServer.assignedNetworks`, then a second `syncServerState()` re-persists the cleaned value to the server record on the very first cycle (not the second). |
| `frontend/src/admin/pages/Servers.svelte` | New "Delete" button on every assignment row. Two-stage confirm (`confirm()` + typed `prompt()`) so a misclick can't nuke a network. Ghost rows get a different prompt copy explaining it's a server-record scrub, not a Mongo delete. |
| `frontend/src/admin/pages/Servers.svelte.test.ts` | 7 regression tests — covers the happy path, cancel path, typo-protection, API-error surface, ghost-row rendering, and the orphan-specific prompt copy. |

## Behaviour matrix

| User action | Old behaviour | New behaviour |
|---|---|---|
| Click "Remove" on a real network | Cleared assignment hash; engine re-asserted on next heartbeat | Same (unchanged) |
| Click "Delete" on a real network | n/a | Engine client stopped, Mongo row deleted, Redis state scrubbed, confirm + typed label required |
| Click "Delete" on a ghost row (empty networkId) | n/a | Walks every engine's server record + per-engine mirror, strips the orphan, no Mongo delete attempted |
| Engine boots with dirty `assignedNetworks` | Wrote dirty state every heartbeat | First heartbeat writes dirty, but second `syncServerState()` after the empty-id filter re-persists the cleaned value within the same cycle |
| `assignNetwork("")` called from any caller | Created a ghost row | Refused with `WARN`; returns empty serverId |

## Quickstart for adding a new admin mutation

1. Define the handler in `source/ircfiber/web/admin/api.d` next to the
   existing siblings (e.g. `apiAssignmentDelete`).
2. Register the route in
   `source/ircfiber/web/admin/package.d` under
   `router.post("/api/admin/...")`.
3. Add the matching thunks in `frontend/src/admin/lib/api-client.ts`
   (none required — `api.post` covers arbitrary URLs).
4. Add a button in the relevant Svelte page (`Servers.svelte` in this
   case). For destructive actions, always require a typed-label
   confirmation via `prompt()` matching `label`. Two-stage
   (`confirm()` + `prompt()`) is the established pattern.
5. Add a regression test in the matching `*.svelte.test.ts`. The
   pattern in `Servers.svelte.test.ts` is the most recent one — mocks
   `../lib/api-client` and `../stores/ui` so the test doesn't depend on
   the global pollingEnabled toggle.

## Known issues / open questions

| Issue | Notes |
|---|---|
| Pre-deploy ghost rows persist one heartbeat cycle | The first `syncServerState()` after deploy writes the in-memory `localServer.assignedNetworks` (which on a legacy engine contains the orphan); the second `syncServerState()` after the filter re-persists the clean state within the same cycle. Operators running the SPA during that 10 s window will see the ghost row flicker. The Delete button scrubs it instantly if needed. |
| `deleteNetworkCore` walks every server when scrubbing an empty id | This is the correct behaviour for ghost rows that have no canonical assignment, but a malicious `networkId=""` payload could theoretically hit many servers. The endpoint is admin-gated and the prompt copy makes the action obvious; we accept the trade-off. |
| Test framework constraints | `frontend/src/admin/pages/Servers.svelte.test.ts` uses `vitest-browser-svelte` + playwright and is therefore blocked in worktrees (symlinked `node_modules` + URL-encoded spaces in path). Run from the parent repo on macOS / Linux. The 2 unrelated failures in `ServerLogCard.test.ts` and `ircStore.svelte.test.ts` are pre-existing on main and not introduced by this change. |

---

# IRC Fiber — Deploy (gateway-only, engine untouched)
The live host is `vps-efb4b52d` (`203.0.113.10`). Inventory `deploy/inventories/production/hosts.ini` lists `vps-efb4b52d`; the gateway/engine both run there.

The engine (`ircfiber-engine-ovh`, PID 7) holds all IRC TCP/TLS sockets. Restarting it drops every network for ~1s (TLS soft-reconnect) and risks nick collisions. A frontend/CSS change must not touch it.

## When this applies

* Only `frontend/` or `backend/views/index.dt` changed (Vite content-hash). `make frontend` rewrites `public/dist/assets/main-*.js` + `backend/views/index.dt` (the Diet template that injects the hashed `<script>`). No D code changed.
* Do **not** run `make update` / `playbooks/deploy-update.yml` — that builds `builder` → extracts both `irc-fiber` + `irc-fiber-engine` → `docker restart ircfiber-gateway` **and** engine hard-restart (handoff removed 2026-08-08). Use the gateway-only path below.

## Procedure (Aug 2026, verified on `vps-efb4b52d`)

```bash
# 1. Build frontend locally (deterministic hash, e.g. main-k8PJwXAF.js)
make frontend-build   # vite build + inject-manifest → public/dist + backend/views/index.dt
#    (use `make frontend` when a LOCAL dev gateway container is running —
#     it additionally rebuilds that container so 127.0.0.1:8090 serves the bundle)
ls -lh public/dist/assets/ | grep main
cat backend/views/index.dt | grep main

# 2. Sync to host's build context (host builds gateway image FROM this context)
tar cz --no-xattrs --format=ustar -C public dist | ssh -F /dev/null -o IdentitiesOnly=yes -i ~/.ssh/id_ed25519_ircfiber deploy@203.0.113.10 'sudo sh -c "rm -rf /opt/ircfiber-src/public/dist && mkdir -p /opt/ircfiber-src/public && tar xzf - -C /opt/ircfiber-src/public"'
cat backend/views/index.dt | ssh -F /dev/null -o IdentitiesOnly=yes -i ~/.ssh/id_ed25519_ircfiber deploy@203.0.113.10 'sudo tee /opt/ircfiber-src/backend/views/index.dt >/dev/null'

# 3. Rebuild gateway image on host (runtime-gateway never compiles engine)
ssh -F /dev/null -o IdentitiesOnly=yes -i ~/.ssh/id_ed25519_ircfiber deploy@203.0.113.10 'cd /opt/ircfiber-src && DOCKER_BUILDKIT=1 docker build --target runtime-gateway -t kevindpostal/irc-fiber-gateway:0.3.0 -f Containerfile .'

# 4. Recreate gateway container only (engine stays PID 7)
ssh -F /dev/null -o IdentitiesOnly=yes -i ~/.ssh/id_ed25519_ircfiber deploy@203.0.113.10 '
  sudo docker stop ircfiber-gateway && sudo docker rm ircfiber-gateway
  sudo docker run -d --name ircfiber-gateway --restart unless-stopped \
    --network ircfiber_net --network ircfiber_logging \
    -v ircfiber_uploads:/app/uploads -v ircfiber_logs:/var/log/irc-fiber \
    --env-file /etc/ircfiber/gateway/env -p 8090:8090 \
    kevindpostal/irc-fiber-gateway:0.3.0 /app/irc-fiber
  sudo docker network connect ircfiber_logging ircfiber-gateway 2>/dev/null || true
'
# Alternative if host still uses docker-compose for gateway:
#   ssh deploy@203.0.113.10 'cd /opt/ircfiber-src && docker compose build ircfiber-gateway && docker compose up -d --force-recreate ircfiber-gateway'

# 5. Keep old hash for 1h Cloudflare edge cache (Cache-Control: public, max-age=3600 on HTML)
#    The new HTML references main-k8PJ..., but CF may still serve cached HTML referencing main-Dlu...
#    for up to 1h. Without the alias the old JS 404s (edge caches 404s too — purge token lacks Zone:Cache Purge).
ssh -F /dev/null -o IdentitiesOnly=yes -i ~/.ssh/id_ed25519_ircfiber deploy@203.0.113.10 '
  sudo docker exec ircfiber-gateway sh -c "cp /app/public/dist/assets/main-k8PJwXAF.js /app/public/dist/assets/main-Dlu0gYHA.js 2>/dev/null; ls -lh /app/public/dist/assets/ | grep main"
  sudo sh -c "cp /opt/ircfiber-src/public/dist/assets/main-k8PJwXAF.js /opt/ircfiber-src/public/dist/assets/main-Dlu0gYHA.js 2>/dev/null; ls -lh /opt/ircfiber-src/public/dist/assets/ | grep main"
'
```

Verification (`engine untouched`):
```bash
ssh -F /dev/null -o IdentitiesOnly=yes -i ~/.ssh/id_ed25519_ircfiber deploy@203.0.113.10 'docker exec ircfiber-engine-ovh pidof irc-fiber-engine; docker ps --format "{{.Names}} {{.Status}}" | grep -E "gateway|engine"; docker exec ircfiber-gateway sh -c "curl -fsS http://localhost:8090/health | head -5"; curl -s -o /dev/null -w "%{http_code} " https://ircfiber.com/public/dist/assets/main-k8PJwXAF.js; echo'
# → engine PID 7, gateway Up <1m, health healthy, 200
curl -s https://ircfiber.com/public/dist/assets/main-k8PJwXAF.js -o /dev/null -w "%{http_code}\n"  # 200 via CF
```

* If you also need to stop the 404 for the *previous* hash immediately and the vault CF token lacks purge, add the alias as above — it costs one extra 469K file and avoids a 1h 404 window. Remove the alias on the next deploy after the edge TTL expires.*
* Host SSH must use `-F /dev/null -o IdentitiesOnly=yes -i ~/.ssh/id_ed25519_ircfiber` — the default `IdentityAgent` (1Password) offers too many keys and hits `Too many authentication failures`. `deploy/.vault_pass.txt` supplies the vault password for `ansible-vault view` but is not needed for this gateway-only tar+docker path.*
