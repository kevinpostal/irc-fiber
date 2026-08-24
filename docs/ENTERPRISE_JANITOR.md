# Enterprise Engine Janitor — Design & Ship Plan

**Status:** In progress · **Owner:** engine + platform

## Problem statement

The IRC Fiber architecture has orphan-engine and orphan-network cleanup gaps that
manifest as "zombie" UI state — e.g. opening `/irc/Gang Net/channel/tclmafia`
shows 16 live nicks even though the engine that owned that connection died days
ago.

Five failure modes:

| # | Failure | Symptom |
|---|---------|---------|
| 1 | Engine SIGKILL'd mid-flight | Per-network state keys (`irc:state:*`, `scrollback:*`, `dedup:*`) persist forever — gateway can route to a dead server but frontend still renders cached nicks |
| 2 | Same `serverId` reused after crash | New epoch inherits garbage from prior epoch; tested-engine code paths get exercised against fossilized state |
| 3 | `make stop` doesn't wipe namespace | Ctrl-C + restart leaves 40+ keys behind (the `testengine1` case on Jun 22) |
| 4 | No global janitor | All existing cleanup paths live INSIDE engine processes. When ALL engines are dead, nothing cleans up. |
| 5 | Frontend caches last-known nicklist | Even after backend heal, browser renders the dead-engine's ghost until manual cache invalidation |

## Architecture: 10 layers

### Layer 1 — TTL on every state key

Every per-engine state key is written with `EXPIRE <ttl>`. Engine heartbeat
bumps TTL each cycle. Default: **600 s** (engine heartbeats every 10 s → 60× safety).

**Scope:**
- `irc:state:<server>:<network>` (registry/server-side state snapshots)
- `scrollback:<server>:<network>:<channel>` (already has 30-day TTL)
- `dedup:<server>:<network>:<channel>` (already has 30-day TTL)
- `irc:stream:<user>` (events) — keep but bound
- `irc:network-fail:<network>` — bound to 24 h
- `irc:control:<server>` — bumped by heartbeat (5 min)

Engine heartbeat task gains a `bumpStateTTLs(serverId)` step — `SCAN MATCH
"irc:state:<server>:*" COUNT 1000` + `EXPIRE` each; `SCAN MATCH "scrollback:<server>:*" COUNT 1000` + `EXPIRE` each. Batching via MULTI/EXEC for atomicity.

### Layer 2 — Distributed `EngineJanitor`

Race-safe, globally-elected janitor that runs in **every process** (gateway +
each engine). Elections are cheap — only one wins per cycle.

**Algorithm:**
1. `SET irc:janitor:lock <pid>:<epoch> NX EX 30` — atomic election
2. Acquired → for each `serverId` in `irc:servers`:
   - `EXISTS irc:server:<id>` → skip (live)
   - Else → atomic reap via Lua (Layer 2b)
3. Release lock (`DEL` if value matches ours)

**Layer 2b — atomic reap (Lua script):**

```lua
-- Inputs: ARGV[1] = serverId, ARGV[2] = batch_size
-- Steps:
--   1. Re-check irc:server:<id> exists (race guard)
--      If still exists → return 0 (someone revived between scan and now)
--   2. SCAN cursor, MATCH *:<id>:* COUNT <batch_size>
--   3. UNLINK each matched key (non-blocking)
--   4. SREM irc:servers <id>
--   5. DEL irc:server-assignments:<id>, irc:control:<id>
--   6. LPUSH irc:janitor:events {json}, LTRIM 1000
--   7. Return count deleted
```

Lua is atomic — no other writer can resurrect the server during the reap. SCAN
iterates in batches of 1000 to avoid blocking. UNLINK hands work to a Redis
background thread (Redis ≥ 4.0, all supported versions).

**Heartbeat — `getReapResult` callback:** janitor gets a `RedisReaper` channel
event whenever the gateway's pub/sub on `irc:shutdown` fires, so handoffs
trigger immediate cleanup of the old serverId.

### Layer 3 — Bootstrap namespace purge

Top of `bootstrapEngine()` (after Mongo connect, before network load):

```d
bool purgeOnBoot = env!bool("IRCFIBER_BOOTSTRAP_PURGE", true);
if (purgeOnBoot && !handoff) {
    purgeLocalServerNamespace(serverId);  // SCAN UNLINK *:<serverId>:*
}
```

This prevents "testengine1 was used Jun 22, today I reuse it" → no carryover.
The handoff path (`IRCFIBER_RELOAD_FROM_PID`) skips purge — adopted sockets
need their state preserved.

### Layer 4 — Handoff cleanup hook

After successful handoff in `engine/reload_orchestrator.d`:

1. Capture `oldServerId` from environment (`IRCFIBER_RELOAD_FROM_PID`)
2. Once new engine is `connected:connected`, schedule a janitor reap of
   `oldServerId` for 30 s later (give `accept` time to drain)
3. Idempotent: if old serverId already gone, reap is a no-op

### Layer 5 — Audit log + observability

`irc:janitor:events` — Redis LIST (capped at 1000 via `LTRIM`).

Each event JSON:
```json
{
  "ts": 1782703502123,
  "kind": "engine_reap" | "namespace_purge" | "shutdown_cleanup" | "manual",
  "serverId": "testengine1",
  "actor": "pid:19490:host=zodiac-mbp",
  "reason": "lease_expired",
  "keysDeleted": 42,
  "durationMs": 47
}
```

Admin endpoints:
- `GET /api/admin/janitor/events?limit=100`
- `GET /api/admin/janitor/status` — current lock holder, last cycle, orphan count
- `POST /api/admin/janitor/reap/<serverId>` — manual reap (admin-only, idempotent)

### Layer 6 — Configuration governance

| Env var | Default | Range | Purpose |
|---|---|---|---|
| `IRCFIBER_JANITOR_INTERVAL` | 60 | 5–3600 | Seconds between janitor cycles |
| `IRCFIBER_STATE_TTL` | 600 | 60–86400 | TTL for state keys (seconds) |
| `IRCFIBER_BOOTSTRAP_PURGE` | true | bool | Wipe local namespace on boot |
| `IRCFIBER_JANITOR_LOCK_TTL` | 30 | 5–300 | Janitor lock TTL (seconds) |

Validated at startup with fail-fast on invalid values.

### Layer 7 — Test matrix

Standalone D test binaries (matching existing pattern in `tests/`):

| Binary | Verifies |
|---|---|
| `tests/janitor_unit.d` | Lua reap of mock namespace; idempotency |
| `tests/janitor_lock.d` | Two processes compete for `irc:janitor:lock` — only one wins per cycle |
| `tests/janitor_safety.d` | Reap refuses to run when `irc:server:X` still exists (race window) |
| `tests/janitor_handoff.d` | After handoff, old serverId is reaped within 60 s |
| `tests/janitor_state_ttl.d` | State keys written with TTL auto-expire when no heartbeat |

Runners: `run-janitor-tests.sh` (drives them all).

### Layer 8 — Migration tool

`source/tools/janitor_migrate.d` — one-shot binary:

- `JSMIGRATE_DRY_RUN=1` (default): scan all `irc:state:*` and report counts
- `JSMIGRATE_DRY_RUN=0`: write TTL to every key without one
- Idempotent — safe to re-run

Wired into `make janitor-migrate` target.

### Layer 9 — Ops tooling

Makefile targets:
- `make janitor-audit` — tail last 50 events
- `make janitor-reap SERVER=testengine1` — manual reap
- `make janitor-status` — current state

Updated `make stop` — also `redis-cli --scan --pattern '*:<serverId>:*' |
xargs redis-cli DEL` plus handoff-socket rm.

### Layer 10 — Frontend defense

`frontend/src/stores/ircStore.svelte.ts`:
- Track `lastSeenAt` per network
- On any new event from server, refresh `lastSeenAt`
- After 5 min without server contact, mark network `stale: true`
- UI shows subtle grey "● offline" pill on stale buffers

`preferences.svelte.ts`:
- Wrap localStorage buffer cache with TTL key — entries > 24 h auto-pruned
- On `online` / `offline` window events, mark all buffers dirty; refresh on
  reconnect

## Rollout sequence

| Wave | Files | Verification |
|---|---|---|
| 1 | `redis/protocol.d`, `storage/buffer.d`, `irc/registry.d`, `engine/bootstrap.d` | `make test` (existing tests) |
| 2 | new `irc/engine_janitor.d`, new `engine/heartbeat_ttl.d` | new tests |
| 3 | `engine/bootstrap.d`, `engine/handoff.d`, `engine/reload_orchestrator.d` | new test |
| 4 | new `web/admin/janitor.d`, `Makefile`, `AGENTS.md`, new `tools/janitor_migrate.d` | curl admin endpoints |
| 5 | `frontend/src/stores/ircStore.svelte.ts`, `preferences.svelte.ts` | vitest client suite |

## Failure coverage matrix (post-deploy)

| Scenario | Old behavior | New behavior |
|---|---|---|
| Engine SIGKILL | State persists forever | TTL wipes within 600 s; janitor reaps within 60 s |
| Ctrl-C on `make debug-live` | Dead state on disk | `make stop` purges; bootstrap-purge on next boot |
| Two janitors running | Last write wins (corruption) | Lua atomicity + global lock |
| Same serverId reused | Garbage carryover | Bootstrap purge wipes namespace |
| Handoff completed | Old serverId lingers in `irc:servers` | Hook schedules reap 30 s post-handoff |
| Admin runs manual reap | No endpoint | `POST /api/admin/janitor/reap/:id` |
| Existing data without TTL | Mixed TTL/no-TTL | `janitor_migrate` tool backfills in one pass |
| Frontend stale cache | Forever ghost | `lastSeenAt` 5-min decay + UI indicator |
