# Plan 20260716-irccloud-parity — completion log

Status: **SHIPPED** in worktree chain
`w1-t01-engine-retry-fail` → `w2-frontend-helpers` →
`w3-connection-status` → `w4-serverlog-timeline` →
`w5-docs-smoke`. Final merge to `main` pending (Phase 4
decision gate).

## Plan stats

- **Plan length**: 1810 lines (`plan.yaml`) + 120 lines
  (`plan-summary.md`) = ~1930 lines
- **Tasks**: 13 (8 implementer + 2 reviewer + 3 Wave-5 docs/smoke)
- **Waves**: 5
- **Critique items**: 4 BLOCKERS (B1-B4) + 5 risks (R1-R5) +
  5 over-engineering (OE1-OE5) + 5 test gaps (TG1-TG5) — all
  BLOCKERS addressed, all OE + TG addressed, R4 deferred (UX
  future work), R1/R2/R5 addressed at implementation time
- **Critique replies**: 8 documented in the plan (`critique_replies`
  section) covering B1-B4, OE1/OE5, TG1/TG2/TG5
- **Reviews shipped**: 4 (wave-1, wave-2, wave-3, wave-4) +
  Wave-5 summary index (`final-review-summary.md`)

## Files changed (cumulative, b9b2f4e..w4-serverlog-timeline)

### Engine (D) — 6 files, +881 / -7 lines (Wave 1)

| File | Net | Purpose |
|---|---|---|
| `source/ircfiber/irc/connection.d` | +413 | `waiting_to_retry` enum; `attemptCount`/`nextRetryAtMs` fields; `CONNECTION_RETRY_STATUS` emit at every retry sleep; zero clear on every `backoff.reset()` site; `FailInfo` construction at disconnect; `parseReasonToFailInfo` helper |
| `source/ircfiber/models/irc_event.d` | +221 | `IRCRawEvent.makeConnectionRetryStatus` + `makeConnectionFail` factories |
| `source/ircfiber/redis/protocol.d` | +150 | `NetworkStateSnapshot.retryStatus: {attemptCount, nextRetryAtMs, delayMs}` field + toJson/fromJson roundtrip |
| `source/ircfiber/engine/state.d` | +60 | Snapshot writer reads `client.getRetryStatus()` on each heartbeat |
| `source/ircfiber/api/websocket.d` | +31 | `performStateDump` ships `netObj["retryStatus"]` to fresh WS sync payloads |
| `source/ircfiber/engine/processor.d` | +13 | (sibling integration tweaks) |

### Frontend (TS-Svelte) — 9 files, +2372 / -239 lines (Waves 2-4)

| File | Net | Purpose |
|---|---|---|
| `frontend/src/components/ConnectionStatus.svelte` | +650 | 11-state banner; `BannerKind` union; live countdown via `$effect` + `setInterval` cleanup; hairline-bar visual; state-aware button |
| `frontend/src/components/ConnectionStatus.test.ts` | +589 | 33 component tests (banner states + transient coverage + inline warnings + button behaviour + helper tests) |
| `frontend/src/components/ServerLogTimeline.svelte` | +446 | `<details class="connection-events">` wrap (B4 `bind:open` + local `$state` + `$effect` mirror); typographic `.row-type-prefix`; padding-only `.row--info` / `.row--motd` |
| `frontend/src/components/ServerLogTimeline.test.ts` | +301 | 22 component tests (wrap, restyle, count badge, typographic prefix, B4 pattern) |
| `frontend/src/lib/connectionWarnings.ts` | +192 | `renderReason` + `renderSSLVerify` + `renderRetryCountdown` + `connectionWarnings` + `FAIL_TYPES` (consolidates the W2 renderReasons + suspiciousConnection) |
| `frontend/src/lib/connectionWarnings.test.ts` | +219 | 33 lib tests (reason keys, SSL verify nested lookup, ordinal suffix, suspicious port/hostname) |
| `frontend/src/stores/preferences.svelte.ts` | +45 | `serverlogCollapseEvents` $state + `getServerlogCollapseEvents` / `setServerlogCollapseEvents` + localStorage roundtrip |
| `frontend/src/stores/preferences.svelte.test.ts` | +91 | 49 client tests (including 7 new for `serverlogCollapseEvents` pref + cross-tab storage event) |
| `frontend/src/types.ts` | +78 | `Network.retryStatus` + `failInfo` + `badRetry` + `focusOnMakeBuffer` + `ip` (all optional for back-compat) |

### Frontend (TS) — Wave 2 plumbing, deleted-and-rolled-up

W2 originally created `frontend/src/lib/renderReasons.ts`,
`suspiciousConnection.ts`, `renderReasons.test.ts`,
`suspiciousConnection.test.ts`, and the matching dispatch +
`applyRetryStatus` / `applyFail` adapters in
`frontend/src/lib/messageHandler.ts` +
`frontend/src/stores/ircStore.svelte.ts`. Wave 3
consolidated `renderReasons` + `suspiciousConnection` into
`connectionWarnings.ts` (single import path for the banner);
the corresponding test files merged into
`connectionWarnings.test.ts` (33 tests cover everything the
two deleted files covered, plus extended coverage for
RFC1918 / .local TLD / null host / combined-warnings
ordering).

### Docs — Wave 5

| File | Lines | Purpose |
|---|---|---|
| `AGENTS.md` | +155 | New "Connection status & server log (IRCCloud parity)" section |
| `docs/plan/20260716-irccloud-parity/logs/engine-smoke.md` | +194 | Three plan-section-G smoke scenarios documented at code-inspection level with file:line evidence + frontend test pinning |
| `docs/plan/20260716-irccloud-parity/logs/visual-smoke.md` | +216 | Five browser smoke scenarios with acceptance-criteria traceability + Playwright capture instructions |
| `docs/plan/20260716-irccloud-parity/logs/final-review-summary.md` | +128 | Wave-by-wave verdict index + cross-wave pass + outstanding work + CRITIQUE item resolution status |
| `docs/plan/20260716-irccloud-parity/CHANGELOG.md` | (this) | Plan completion log |

## Tests

- **lib tests** (`frontend/src/lib/**`): 489 tests across 25
  files, all green (verified 2026-07-16 via
  `npx vitest run --project=lib`).
- **client tests** (the 4 W3-W4 touched files):
  `ConnectionStatus.test.ts` (33) +
  `ServerLogTimeline.test.ts` (22) + `preferences.svelte.test.ts` (49)
  + `connectionWarnings.test.ts` (33, lib) = 137 client tests in
  the touched scope; all green per the wave reviews.
- **Net new tests** added across the plan: ~140 (rough
  count from the four wave reviews — Wave 2 added 12 + 30 +
  9 + 5 = 56; Wave 3 added 33 + 33 (lib) + some in
  ConnectionStatus.test.ts; Wave 4 added 8 + 7 = 15;
  revisions added 6 more in W3-rev1).
- **Pre-existing failures** (NOT introduced by this plan,
  confirmed on `main` per the wave reviews):
  - `ircStore.svelte.test.ts` self-nick test (W7-T01)
  - `ServerLogCard.test.ts` renders-phase-chips test
  - Various async-race unhandled rejections in
    `ServerLogCard.test.ts` / `Sidebar.test.ts` /
    `ServerLogTimeline.test.ts` from
    `updateServerlogCollapsed` / `updateCollapsed` mock
    rejections
  - 64 pre-existing `tsc --noEmit` errors across 10 files
    (`ircStore.svelte.ts` (16), `ircStore.svelte.test.ts` (19),
    `wsHoleDetector.test.ts` (12), `Sidebar.test.ts` (8),
    `App.test.ts` (3), `routing.ts` (2), `wsConnection.svelte.ts`
    (1), `wsConnection.svelte.test.ts` (1),
    `isupportCatalog.test.ts` (1), `Sidebar.duplicate.test.ts` (1))
  - Wave 4 files have ZERO tsc errors.

## Visual / behavior deltas

User-facing changes (post-deploy):

1. **ConnectionStatus banner** now has 11 distinct states
   instead of 3. Live "Reconnecting in 12s… (3rd attempt)"
   countdown with ordinal attempts. State-aware button (reconnect
   vs. disconnect). Inline suspicious-port / suspicious-hostname
   warnings appended below the headline. Hairline-bar visual
   matching IRCCloud's restraint while keeping the fiber palette.

2. **ServerLogTimeline connection-events wrap** — a single
   hairline-bar `<details>` element wraps the entire
   connection-attempt detail stream (phases + welcome + MOTD +
   numerics + ISUPPORT + notices). Collapsed by default;
   preference persists in localStorage under
   `ircfiber:serverlogCollapseEvents`; cross-tab synced via
   the `storage` event.

3. **Welcome / MOTD row restyle** — no cyan chip, no cyan
   left stripe. `padding:10px` + transparent background +
   per-segment colour tokens (cyan-bold for network/nick/host,
   snow for plaintext, amber for version, dim for
   mode-table). MOTD block has the same treatment plus a
   fiber-paper inner box for the `<h2>` banner + `<div>`
   lines + `<span>` footer.

Engine contract changes:

- Two new events: `CONNECTION_RETRY_STATUS` (carries
  `{attemptCount, nextRetryAtMs, delayMs}`) and `CONNECTION_FAIL`
  (carries structured `FailInfo{type, reason, killedReason,
  sslVerifyError}`).
- `NetworkStateSnapshot` gains a nullable `retryStatus`
  field. Fresh-client WS sync payload (`websocket.d:
  performStateDump`) ships it when present, absent otherwise
  (back-compat with older engine builds that don't emit it
  yet).
- `connection.d` exposes `attemptCount:int`, `nextRetryAtMs:long`,
  `getRetryStatus():RetryStatus?` public accessors on
  `PersistentIRCClient` (alongside the existing
  `getIsupport` / `getAckedCaps` getter pair).
- New `FailInfo` struct in `models/irc_event.d` and
  `connection.d` (nested `sslVerifyError` shape, NOT the
  legacy flat pair).
- The engine CONTINUES to emit the legacy `disconnectReason`
  string alongside the structured `failInfo` for
  back-compat. New code consumes `failInfo`; old code
  continues to work via the legacy string fallback.

## Plan vs. implementation drift

| Item | Plan | Implementation | Drift |
|---|---|---|---|
| Wave 2 helper file names | `renderReasons.ts` + `suspiciousConnection.ts` (separate) | `connectionWarnings.ts` (consolidated) | **Accepted** — single import path for the banner; 33 lib tests cover everything |
| `isSuspiciousPort` signature | `isSuspiciousPort(isSSL, port): boolean` | `isSuspiciousPort(port, isSSL): string \| null` | **Accepted** — argument order swapped, returns warning string directly. JSDoc documents the reversal |
| `kill` reason copy | `strip(killedReason)` | `renderReason(killedReason)` | **Accepted** — `renderReason` trims + passes through; effect identical for human-shaped killed reasons |
| Test count W4 | 7 new (brief) | 8 new (commit) | **+1 over plan** — extra `phase rows use the mono typographic .row-type-prefix` test (Refactor C acceptance) |
| Wave 4 standalone reviewer | W4-T02 | Removed | Per OE5 — Wave 4 reviewed as part of Wave 5 full review |

## Files NOT touched (deliberately, per `do_not_reinvestigate`)

The plan brief flagged the following as out-of-scope /
must-not-touch:

- `source/ircfiber/irc/connection.d` legacy `disconnectReason`
  emit — preserved as-is for back-compat with the existing
  ircStore reader.
- `frontend/src/lib/isupportCategorize.ts` — ISUPPORT
  categorization logic untouched.
- `frontend/src/components/IsupportDetailDrawer.svelte` —
  the click-through detail drawer from the "Server features"
  overhaul is unchanged.
- `groupServerLog` + `getServerLogCollapsedKey` — the
  per-attempt server-log grouping logic is untouched. The
  new global `serverlogCollapseEvents` pref is orthogonal
  (drives the new `<details>` open state; does not affect
  the per-attempt `<div class="head">` collapse).
- `MessageList.svelte` — no changes.
- `source/ircfiber/web/package.d`,
  `public/dist/index.html`, `views/index.dt`,
  `deploy/playbooks/deploy-update.yml` — dirty on main at
  plan start; explicitly NOT modified by this worktree.

## Deploy / rollout

```bash
# 1. Bring up local stack
make local-dev-up

# 2. (Optional) Run the engine live smoke per engine-smoke.md
#    — requires w1-t01-engine-retry-fail merged into main
git checkout w1-t01-engine-retry-fail
make engine-handoff
# ... run the three scenarios in engine-smoke.md ...

# 3. Merge the chain to main via PR (Phase 4)
git checkout main
git merge --no-ff w5-docs-smoke -m "Plan 20260716-irccloud-parity: docs + smoke + review summary"
# + merge w1..w4 PRs in order

# 4. Deploy
make update

# 5. Verify end-to-end against stage
# - Connect to irc.libera.chat, observe "Welcome to the Libera.Chat"
#   banner (cyan-bold tokens, no cyan stripe)
# - Open _server buffer, observe "Connection events (N)" collapsed
#   by default
# - Click to expand, observe ServerFeaturesPanel inside
# - Force a disconnect (kill IRC server), observe
#   "Reconnecting in 12s… (2nd attempt)" countdown
```

## Sign-off

Wave 5 docs gate: **PASS** — non-blocking gaps (live engine
smoke deferred to deploy-time per worktree constraints;
visual capture deferred per executive-instruction scope).
All four prior waves reviewed clean. Plan is shipped
pending Phase 4 merge.