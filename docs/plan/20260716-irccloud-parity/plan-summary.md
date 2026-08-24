# Plan 20260716-irccloud-parity - IRCCloud parity for Connecting / Server log

## Problem statement

IRC Fiber's Connecting / Server log surface has three user-visible gaps:

1. **Silent data drop.** The 3-state banner omits eight lifecycle states, retry timing,
   ordinal attempts, structured failures, and suspicious connection warnings.
2. **Always-expanded card.** Attempt phases, welcome rows, MOTD, numerics, ISUPPORT,
   and notices are always visible instead of sitting behind one restrained disclosure.
3. **Cyan-stripe rows.** Welcome and MOTD use cyan chips, fills, and stripes instead of
   IRCCloud's quieter `type_status`, `type_info_response`, and `type_motd_response` grammar.

## Behavior matrix

| # | Behavior | Today | After |
|---:|---|---|---|
| 1 | `waiting_to_retry` (will retry) | Generic reconnect copy; no timer or ordinal | `Reconnecting in {delay}s ({Nth} attempt)` |
| 2 | `waiting_to_retry` (give up) | Generic reconnect copy | `Reconnecting...` |
| 3 | `queued` | Folded into `Connecting...` | `Connection queued; waiting our turn...` |
| 4 | `connecting` | `Connecting...` | `Connecting to {host}...` |
| 5 | `connected` | Hidden or treated as fully connected | `Connected; handshaking...` |
| 6 | `connected_joining` | Hidden or treated as fully connected | `Connected; setting up...` |
| 7 | `quitting` | Generic disconnected copy | `Quitting...` |
| 8 | `ip_retry` | IP and error detail dropped | `Connecting to {ip} failed ({error}); resolving a new IP...` |
| 9 | `disconnected` (not failed) | `Click to reconnect` without structured context | `Disconnected` with a state-aware reconnect action |
| 10 | `connected_ready` (`focusOnMakeBuffer === '*'`) | Hidden | `Connected; waiting to join...` |
| 11 | `connected_ready` (channel target) | Hidden | `Connected; waiting to join {chan}...` |
| 12 | Failure reason | Free-text `disconnectReason` only | Structured `failInfo` rendering with legacy fallback |
| 13 | Retry progress | No live countdown or attempt ordinal | 1s countdown plus `1st`, `2nd`, `3rd`, and later attempts |
| 14 | Suspicious connection | No port or hostname warning | Inline suspicious-port and suspicious-hostname warnings |
| 15 | Connection events | Attempt rows always expanded | One `Connection events (N)` disclosure, collapsed by default |
| 16 | Welcome rows (`001`-`004`) | Cyan chip, fill, and left stripe | `type_info_response` spacing and typography; no stripe |
| 17 | MOTD and NOTICE rows | Cyan fill/chip treatment | `type_motd_response` and mono `type_notice` prefixes |

## Root causes

- The 3-state banner lacks eight states, a countdown, ordinal attempts, and rich failure rendering.
- ServerLogTimeline has no single collapse-events pattern around all connection-attempt rows.
- `.row--info` and `.row--motd` use cyan chips and stripes instead of `type_status` typography.

## Design decisions

- **Full parity scope:** include engine, additive wire/snapshot data, frontend state, behavior, and visuals.
- **Global collapse preference:** `serverlogCollapseEvents` is global and defaults to collapsed.
- **Compatibility transition:** emit both legacy `disconnectReason` and structured `failInfo`.
- **Structured failures:** render reason, SSL verification, killed, blocked, and restricted branches.
- **Connection warnings:** port `isSuspiciousPort` and `isSuspiciousHostname` as pure helpers.
- **Brand boundary:** reuse IRCCloud's visual grammar while keeping the fiber palette and fonts.

## File map

### Engine D

| File | Change |
|---|---|
| `source/ircfiber/irc/connection.d` | Track retry attempt/deadline, emit retry/fail events, and keep legacy reason emission. |
| `source/ircfiber/models/irc_event.d` | Add `FailInfo` plus retry-status and connection-fail event factories. |
| `source/ircfiber/redis/protocol.d` | Add backward-compatible `retryStatus` to `NetworkStateSnapshot`. |
| `source/ircfiber/engine/state.d` | Populate the additive retry snapshot from `PersistentIRCClient`. |
| `source/ircfiber/api/websocket.d` | Include `retryStatus` in fresh-client sync when present. |
| `source/connection_registration_test.d` | Extend the registration smoke path for retry and fail events. |

### Frontend TS-Svelte

| File | Change |
|---|---|
| `frontend/src/lib/renderReasons.ts` | Port reason, SSL, restricted, and post-error rendering maps. |
| `frontend/src/lib/renderReasons.test.ts` | Exhaustively pin reason-table behavior in the lib project. |
| `frontend/src/lib/suspiciousConnection.ts` | Add pure suspicious-port and suspicious-hostname helpers. |
| `frontend/src/lib/suspiciousConnection.test.ts` | Cover all helper branches in the lib project. |
| `frontend/src/types.ts` | Add `RetryStatus` and `FailInfo` while preserving `disconnectReason`. |
| `frontend/src/stores/ircStore.svelte.ts` | Apply retry/fail events and adopt additive retry sync state. |
| `frontend/src/lib/messageHandler.ts` | Dispatch `CONNECTION_RETRY_STATUS` and `CONNECTION_FAIL`. |
| `frontend/src/stores/preferences.svelte.ts` | Add the global persisted `serverlogCollapseEvents` preference. |
| `frontend/src/stores/preferences.svelte.test.ts` | Verify default, persistence, and cross-tab storage updates. |
| `frontend/src/components/ConnectionStatus.svelte` | Render 11 states, countdown, failures, warnings, and actions. |
| `frontend/src/components/ConnectionStatus.test.ts` | Cover all states, timer cleanup, failures, warnings, and visuals. |
| `frontend/src/components/ServerLogTimeline.svelte` | Add the disclosure and restyle info, MOTD, status, and notice rows. |
| `frontend/src/components/ServerLogTimeline.test.ts` | Verify disclosure state, row grammar, count, and ISUPPORT nesting. |
| `frontend/src/test/factories.ts` | Supply typed retry and failure defaults for component tests. |

### Docs

| File | Change |
|---|---|
| `docs/plan/20260716-irccloud-parity/plan.yaml` | Existing 13-task, five-wave execution DAG; remains unchanged. |
| `docs/plan/20260716-irccloud-parity/context_envelope.json` | Reusable stack, constraints, architecture, evidence, and decisions. |
| `docs/plan/20260716-irccloud-parity/plan-summary.md` | Human-readable scope, behavior, files, waves, and boundaries. |
| `AGENTS.md` | Add the shipped Connecting / Server log parity architecture and quickstart. |
| `docs/plan/20260716-irccloud-parity/logs/` | Store engine smoke, wave reviews, screenshots, and final review. |

## Wave breakdown

**Wave 1 - 1 task.** Add structured retry/fail tracking in the D engine, emit two
additive events, and carry retry state through snapshots and fresh WebSocket sync.

**Wave 2 - 4 tasks.** Build pure reason and suspicious-connection helpers, wire
frontend state, add the global collapse preference, and prepare the timeline disclosure/restyle.

**Wave 3 - 3 tasks.** Rewrite ConnectionStatus for full state parity, add focused
component coverage for countdown and failures, then pass a dedicated wave review.

**Wave 4 - 2 tasks.** Ship the final ServerLogTimeline connection-events disclosure
and typographic row treatment, then pass the timeline-specific review gate.

**Wave 5 - 3 tasks.** Document the architecture, run five browser smoke scenarios,
and complete the full acceptance-criteria and compatibility review.

Total: **13 tasks across 5 waves**.

## Out of scope

- Join/part grouping in channel buffers.
- `failed` / `failedMessage` pending-row styling.
- Replacing fiber's brand fonts with IRCCloud fonts.

## Open questions

None. All scope, compatibility, collapse, countdown, and migration decisions were answered in this session.
