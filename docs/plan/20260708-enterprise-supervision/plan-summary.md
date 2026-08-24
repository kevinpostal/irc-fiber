# Plan 20260708-enterprise-supervision — Erlang/IRCCloud-inspired architecture

## Problem statement

The current IRC Fiber architecture has a real bouncer split (holder owns the IRC socket, engine does the protocol state), but it lacks the **operational discipline** that makes Erlang+IRCCloud production-grade:

1. **No supervision tree.** The engine's `runConnectionLoop` restarts on exception via `safeFiberRun`, but there's no upper bound on restarts, no crash-window detection, and no permanent-stop escalation. A loop that crashes every 5 seconds will keep restarting forever.

2. **No process isolation.** The holder's IPC server runs in the same event loop as each HolderIRCClient's read loop. A client that does a 5-second syscall (e.g. slow DNS, stuck `recv`) starves every other client's read loop and the IPC accept loop.

3. **No liveness/readiness/metrics split.** The gateway has `/api/health`. The holder has `/healthz`/`/readyz`/`/metrics`. The engine has *nothing* — a stuck engine is invisible until the holder's host circuit breaker fires (5+ minutes later).

4. **No backpressure signals.** A WS client with a slow consumer fills the 64k outbound queue silently. Today the queue is large enough that this rarely happens, but there's no early warning.

5. **Let-it-crash is missing.** When a HolderIRCClient gets into a bad state (e.g. 12 retries of `adoptStream` failed), it throws. The exception propagates up. The IPC server catches it as "the runner crashed" and logs a warning. The client is removed from the map. The engine sees `disconnected` and starts its own reconnect. Good — but the bad state was never signaled to the engine as "you should not try this same network for a while."

6. **Bouncer hot-reload is one-sided.** Engine exec-reload (handoff) keeps the IRC socket alive because the engine doesn't own the socket. But a holder restart drops every IRC connection. There's no path for the IRC socket to survive a holder restart.

## Design principles (borrowed, not copied)

From **Erlang/OTP**:
- *Supervision trees* — every process has a parent that monitors and restarts it
- *Let it crash* — failing fast + restart is better than defensive programming
- *Process isolation* — each process owns its state; no shared mutable state
- *Message passing* — async messages are the only IPC primitive
- *Restart strategy* — normal | transient (backoff) | permanent (stop after N in M)
- *Link/Monitor* — explicit failure detection between processes

From **IRCCloud**:
- *Cursor-based sync* — `maxEid` on client, `since` query param on connect
- *Stream resume* — server replays missed events from durable storage
- *Persistence-first delivery* — events durable in MongoDB before notification
- *Bouncer model* — thin client + server-owned socket
- *Out-of-band fetch* — `/api/oob` for hole filling
- *Per-stream state machine* — clear states for connection lifecycle

What we will **NOT** copy:
- Erlang's actual process model (D has fibers, not processes)
- OTP syntax (we use D's `nothrow` + `runTask` + `runWorkerTask`)
- IRCCloud's exact wire format (we have our own, but the same principles)

## Target architecture

```
┌─────────────────────────────────────────────────────────────────┐
│  Frontend (browser)                                              │
│  - maxEidTracker (single source of truth for "what I have")      │
│  - wsHoleDetector (sliding window; calls /api/oob on gap)        │
│  - Heartbeat ack: send {cmd:"ack",eid:maxEid} every 5s          │
│  - WS with XHR fallback (mirrors IRCCloud's XHRStreamHandler)     │
└─────────────────────────────────────────────────────────────────┘
                              │ WS
                              ▼
┌─────────────────────────────────────────────────────────────────┐
│  Gateway (control plane)                                          │
│  - Per-session WebSocket                                          │
│  - SessionSupervisor (new — monitors each WS for liveness)        │
│  - lastDeliveredEid filter (cursor — never deliver twice)        │
│  - Unbounded outbound queue (65536, log+skip on overflow)        │
│  - Backpressure signal: when queue > 32k, send {backpressure:1} │
│  - /api/oob?since=<eid> (hole-filling recovery)                   │
│  - Persist ack to Redis: irc:session:<id>:ack → <eid>            │
│  - Session persistence: ack survives WS drop, replayed on open   │
└─────────────────────────────────────────────────────────────────┘
            │ Redis pub/sub               │ REST
            ▼                             ▼
┌─────────────────────────────────────────────────────────────────┐
│  Redis (durable bus)                                              │
│  - irc:events:<userId>      (pub/sub, last 1000 buffered)        │
│  - irc:stream:<userId>      (LTRIM 0 9999)                     │
│  - scrollback:<srv>:<net>:<buf>                                │
│  - irc:global_eid          (monotonic counter)                  │
│  - irc:state:<srv>:<netId>  (network state snapshot)           │
│  - irc:session:<id>:ack    (NEW — last acked eid per session)   │
│  - irc:supervisor:<role>:<id> (NEW — heartbeats + liveness)    │
└─────────────────────────────────────────────────────────────────┘
            │
            ▼
┌─────────────────────────────────────────────────────────────────┐
│  Engine (per-network Supervisor)                                  │
│  - 1 IRCClientSupervisor per networkId                            │
│  - 1 IRCClientWorker per networkId (TCP/TLS I/O)                 │
│  - Restart policy (NEW — Erlang-style):                           │
│      * normal: restart on crash with backoff                    │
│      * transient: 5 restarts in 60s → 5min backoff            │
│      * permanent: 10 restarts in 5min → mark "needs help"     │
│  - Liveness: heartbeats every 10s to Redis irc:supervisor:...  │
│  - Cursor: lastDeliveredEid (sent to gateway via session.ack)    │
│  - Persistence-first writes: MongoDB before Redis publish        │
│  - Periodic state snapshots: irc:state:<srv>:<netId>            │
└─────────────────────────────────────────────────────────────────┘
            │ Unix IPC
            ▼
┌─────────────────────────────────────────────────────────────────┐
│  Holder (connection Supervisor)                                  │
│  - 1 HolderIRCClientSupervisor per networkId                     │
│  - 1 HolderIRCClientWorker per networkId (raw TCP/TLS I/O)        │
│  - Cap: MAX_CONCURRENT_CONNECTIONS = 8 (prevents eventcore       │
│    m_fds saturation under burst reconnect)                        │
│  - Restart policy:                                              │
│      * restart worker on crash                                 │
│      * adoptStream failures > 3/60s → circuit break            │
│      * TLS errors > 3/60s → mark host as bad, back off        │
│  - State machine: connecting | registering | connected |        │
│    disconnected                                                  │
│  - Liveness: heartbeats to Redis irc:supervisor:holder:...     │
│  - /healthz, /readyz, /metrics (Prometheus-compatible)          │
│  - Hot-reload: SIGTERM → graceful drain → exit                  │
└─────────────────────────────────────────────────────────────────┘
```

## Per-component changes

### 1. Engine: `IRCClientSupervisor` (new wrapper)

Wrap each `runConnectionLoop` in a supervisor that implements the Erlang restart strategy.

```d
// source/ircfiber/irc/supervisor.d (new)
final class IRCClientSupervisor {
    private {
        NetworkConfig config;
        void delegate() runOnce;        // the actual runConnectionLoop
        ExponentialBackoff backoff;
        int restartCount;
        SysTime firstRestartAt;
        string lastReason;
    }
    enum MAX_RESTARTS_IN_WINDOW = 5;   // transient
    enum WINDOW_SECS = 60;
    enum PERMANENT_RESTARTS = 10;       // permanent
    enum PERMANENT_WINDOW_SECS = 300;

    void supervise() {
        while (true) {
            try {
                runOnce();
                // Normal exit: sleep and restart
                Thread.sleep(dur!"seconds"(1));
                restartCount = 0;
            } catch (Exception e) {
                lastReason = e.msg;
                recordCounter("ircfiber.client.crashed", 1, ...);
                auto now = Clock.currTime;
                if (firstRestartAt == SysTime.init ||
                    (now - firstRestartAt) > dur!"seconds"(WINDOW_SECS)) {
                    // First crash or window expired — reset
                    firstRestartAt = now;
                    restartCount = 0;
                }
                restartCount++;
                if (restartCount > PERMANENT_RESTARTS &&
                    (now - firstRestartAt) < dur!"seconds"(PERMANENT_WINDOW_SECS)) {
                    logError("IRC client for %s reached permanent-failure threshold (%d restarts in %s); marking needs_help",
                        config.name, restartCount, PERMANENT_WINDOW_SECS);
                    // Don't return — let the next supervisor level handle it.
                    // Set state so the engine knows not to retry.
                    state = ConnectionState.disconnected;
                    needsHelp = true;
                    break;
                }
                if (restartCount > MAX_RESTARTS_IN_WINDOW) {
                    auto delay = dur!"seconds"(60);  // 1min backoff
                    logWarn("IRC client for %s in transient-failure window; backing off %s",
                        config.name, delay);
                    Thread.sleep(delay);
                }
            }
        }
    }
}
```

### 2. Holder: `HolderIRCClientSupervisor` (new)

Each HolderIRCClient gets a supervisor. The existing `runConnectionLoop` becomes the worker; the supervisor wraps it.

```d
// source/conn_holder/client_supervisor.d (new)
final class HolderIRCClientSupervisor {
    private {
        string networkId;
        void delegate() runOnce;        // current runConnectionLoop
        IPCServer server;
        int crashCount;
        SysTime firstCrashAt;
    }
    enum RESTART_BUDGET = 3;          // crash 3 times in 60s → mark "broken"
    enum WINDOW_SECS = 60;

    void supervise() {
        while (!server.isShutdown) {
            try {
                runOnce();
            } catch (Exception e) {
                logError("HolderIRCClient[%s] worker crashed: %s", networkId, e.msg);
                crashCount++;
                auto now = Clock.currTime;
                if (firstCrashAt == SysTime.init ||
                    (now - firstCrashAt) > dur!"seconds"(WINDOW_SECS)) {
                    firstCrashAt = now;
                    crashCount = 0;
                }
                if (crashCount >= RESTART_BUDGET) {
                    logError("HolderIRCClient[%s] hit %d crashes in %s — sending disconnect to engine and pausing",
                        networkId, RESTART_BUDGET, WINDOW_SECS);
                    server.notifyDisconnected(networkId, "supervisor: too many crashes");
                    // Wait before retrying
                    Thread.sleep(dur!"seconds"(60));
                    crashCount = 0;
                } else {
                    // Exponential backoff
                    Thread.sleep(dur!"seconds"(1 << crashCount));
                }
            }
        }
    }
}
```

### 3. Holder: per-worker liveness heartbeat

Each HolderIRCClient worker publishes a heartbeat every 10s to `irc:supervisor:holder:<networkId>` with a TTL of 30s. A separate "watcher" process checks all heartbeats and alerts if any are stale.

```d
// in HolderIRCClientSupervisor.supervise
while (!server.isShutdown) {
    auto heartbeat = Json.emptyObject;
    heartbeat["networkId"] = networkId;
    heartbeat["state"] = cast(int) state;
    heartbeat["lastBeatAt"] = Clock.currTime.toUnixTime!long * 1000;
    heartbeat["eid"] = lastEnqueuedEid;
    redis.setJson("irc:supervisor:holder:" ~ networkId, heartbeat, 30);
    // ... rest of supervision
}
```

### 4. Gateway: per-session liveness + session supervisor

Each WS session gets a `SessionSupervisor` that monitors:
- Last ack time (must be < 30s for healthy)
- Outbound queue depth (must be < 32k for healthy)
- Last message received time (must be < 5min for healthy)

A `/api/health`-like endpoint aggregates these.

```d
// new method on SessionManager
SessionHealthStats getSessionHealth() {
    SessionHealthStats stats;
    synchronized (m_mutex) {
        foreach (ref s; sessions) {
            stats.total++;
            if (s.isActive) {
                if (s.outbound.length > 32768) stats.backpressured++;
                if (s.lastDeliveredEid < 0 && s.lastEnqueuedEid > 0) stats.unackedGaps++;
            }
        }
    }
    return stats;
}
```

### 5. Engine: explicit backpressure handling

When the gateway sends a backpressure signal, the engine slows its publish rate. Currently, the engine publishes all events from `eventChannel` in a tight loop. With backpressure, it should:
- Yield more often
- Wait for the WS to drain before publishing more

```d
// in processor.d
if (auto session = sm.getSession(sessionId)) {
    if (session.outbound.length > 32768) {
        // Slow down — let the WS catch up
        Thread.sleep(dur!"msecs"(50));
    }
}
```

### 6. Session persistence: lastDeliveredEid survives WS drop

When the WS closes (e.g. browser tab closed), the lastDeliveredEid should be persisted to Redis so a new WS for the same session (or a new session for the same user) can resume from where it left off.

```d
// in handleWebSocket's finally block, before destroying the session
if (session.lastDeliveredEid > 0) {
    redis.set("irc:session:" ~ session.id.toString() ~ ":ack",
              session.lastDeliveredEid.to!string,
              86400);  // 1 day TTL
}
// And in handleWebSocket's start, restore it
auto persistedAck = redis.get("irc:session:" ~ session.id.toString() ~ ":ack");
if (persistedAck.length > 0) {
    session.lastDeliveredEid = persistedAck.to!long;
}
```

### 7. Observable state machine (every component)

| State | Meaning | Health impact |
|---|---|---|
| `alive` | process running, event loop healthy | healthy |
| `degraded` | one or more subsystems unhealthy | degraded (still serving) |
| `shutting_down` | graceful drain in progress | shutting down |
| `needs_help` | restart budget exhausted | unhealthy |

Each component's `/healthz` returns `alive` or `degraded`. The orchestrator can decide when to restart.

### 8. Metrics catalog (Prometheus-compatible)

Already added for the holder. The engine and gateway should follow the same pattern.

**Holder** (already):
- `ircfiber_holder_up`
- `ircfiber_holder_uptime_seconds`
- `ircfiber_holder_engine_peers`
- `ircfiber_holder_connections_total`
- `ircfiber_holder_connections_connected`
- `ircfiber_holder_client_stale_evictions_total`
- `ircfiber_holder_client_force_reconnects_total`
- `ircfiber_holder_adopt_stream_retries_total` (NEW 2026-07-08)
- `ircfiber_holder_adopt_stream_failures_total` (NEW 2026-07-08)
- `ircfiber_holder_rejected_for_capacity_total` (NEW 2026-07-08)
- `ircfiber_holder_supervisor_crash_count` (NEW this plan)
- `ircfiber_holder_supervisor_state` (NEW this plan, gauge: 0=alive, 1=shutting_down, 2=needs_help)

**Engine** (NEW):
- `ircfiber_engine_up`
- `ircfiber_engine_uptime_seconds`
- `ircfiber_engine_networks_total`
- `ircfiber_engine_networks_connected`
- `ircfiber_engine_supervisor_restart_count` (per network)
- `ircfiber_engine_supervisor_state` (per network)
- `ircfiber_engine_event_backpressure_total`
- `ircfiber_engine_eid_lag_seconds` (global eid - max session.lastDeliveredEid)
- `ircfiber_engine_oob_fetches_total` (number of hole-fills)
- `ircfiber_engine_crash_count_total`

**Gateway** (additions to existing):
- `ircfiber_gateway_session_health` (gauge: 0=alive, 1=degraded, 2=unacked_gap)
- `ircfiber_gateway_backpressured_sessions`
- `ircfiber_gateway_session_supervisor_crash_count`

## Migration plan

This is a large architectural change. Phased rollout:

| Phase | What | Risk | Effort |
|---|---|---|---|
| 1 | Engine: `IRCClientSupervisor` with crash budget | Low (additive wrapper around existing code) | 1 day |
| 2 | Holder: per-worker heartbeat to Redis (observability, no behavior change) | Low | 0.5 day |
| 3 | Holder: `HolderIRCClientSupervisor` (restart on crash) | Medium (could double-restart) | 1 day |
| 4 | Gateway: per-session health tracking + metrics | Low (additive) | 0.5 day |
| 5 | Gateway: backpressure signal when queue > 32k | Low (additive) | 0.5 day |
| 6 | Gateway: persist lastDeliveredEid to Redis | Low (additive) | 0.5 day |
| 7 | Engine: respect backpressure signal in processor | Medium (changes hot path) | 1 day |
| 8 | Engine: explicit `/healthz` + `/metrics` endpoints | Low (additive) | 0.5 day |
| 9 | Cross-process liveness dashboard | Low (read-only) | 0.5 day |

**Total: ~6.5 days of focused work.**

## Test plan

Each phase needs:

1. **Unit tests** — supervisor's restart-strategy logic, crash-window detection, permanent-stop escalation
2. **Integration tests** — engine exec-reload during transient failure; holder crash during active IRC session
3. **Chaos tests** — randomly kill processes during active connections and verify recovery
4. **Load tests** — 5 networks connecting simultaneously must not exceed MAX_CONCURRENT_CONNECTIONS; backpressure must fire before queue overflow

## What's NOT changing

- The IPC wire format (Unix-domain socket, custom binary frames)
- The Redis schema (no new types — just two new keys for supervisor heartbeats and session ack)
- The engine exec-reload (handoff) mechanism — already works
- The basic holder/agent model — we're adding supervision, not replacing

## Open questions

1. **Process model in D** — Erlang's process model is unique. D's `runTask` gives us fibers on the main loop; `runWorkerTask` gives us true OS threads. For the holder's IRC client workers, do we want fibers (cheap, single-threaded) or worker threads (expensive, multi-threaded)? **Recommendation: fibers** for the worker, but allow `runWorkerTask` as an opt-in for CPU-heavy TLS operations.

2. **Where does the supervisor live for the gateway's WS clients?** — Gateway already has per-session fibers. Do we add a session supervisor that monitors each WS for liveness? Or is this overkill? **Recommendation: yes, add a session supervisor** — a stuck WS is exactly the kind of "leaked resource" that supervisors catch.

3. **Hot-reload of holder** — If we want the IRC socket to survive a holder restart, we'd need to migrate the socket to a separate "socket owner" process. Out of scope for this plan; current scale doesn't justify the complexity. **Defer.**

4. **Distributed tracing** — OpenTelemetry instrumentation across engine/holder/gateway. Already partially in place (the engine has OTel metrics). **Defer to a separate plan.**

## References

- Erlang/OTP Design Principles: https://www.erlang.org/doc/design_principles/des_princ.html
- IRCCloud's stream resume protocol (reverse-engineered from `/Users/zodiac/Downloads/webpack/`)
- 2026-07-07 plan: `docs/plan/20260707-realtime-event-delivery/plan-summary.md` (this is the foundation this plan builds on)
- 2026-07-08 plan (this file): adds supervision on top of the cursor protocol
