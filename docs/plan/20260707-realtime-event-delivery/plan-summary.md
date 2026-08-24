# Plan 20260707-realtime-event-delivery — Real-time IRC connection-log streaming

## Problem statement

The user reported on 2026-07-07 that "the server connection logs don't show
in real time when connecting. I have to refresh for them to be seen" — this
was a long-standing UI bug that turned out to be a backend architecture
problem. The `/api/health` endpoint reported `dropped: 1734` for the gateway
session queue, meaning ~1700 frames had been silently dropped on the way
from the Redis pub/sub to the WebSocket.

## Root cause

The gateway's per-session outbound queue was a `RingBuffer!string(500)`
with **drop-oldest on overflow**. The intended model was:
- Buffer absorbs in-flight burst (replay of ~1000 missed events on
  reconnect) without blocking the producer.
- When the buffer fills, drop the OLDEST so the newest survive
  (chat-tail coherence).
- Eventually the WS catches up and the buffer drains.

The actual model was: the buffer fills in the burst, drops 500
replay events, then 500 more live events flow in. As the live
events try to enqueue, the buffer is full of the replayed events
that were just dropped. The ircPoolDispatch's listener (running on
`g_ircPool`) tries to enqueue live events but they're dropped
oldest. The producer never blocks. The drain processes the replay
backlog that survived. **The live events the user wanted to see
are gone.** The next refresh replays them from the durable scrollback
(which is why refresh "fixes" the bug — it's a replay, not the
in-memory path).

The compounding factors:
1. The replay (1000 events) is sent directly to `sessionManager.sendToSession`
   which enqueues to the same 500-slot ring buffer. If the queue
   is at 500, the 501st send drops the oldest.
2. The `ircPoolDispatch` listener on `g_ircPool` ALSO enqueues to
   the same buffer. Live events are dropped while the replay is
   still in flight.
3. The `coalescedN` counter silently accumulated. The
   `/api/health` endpoint exposed `dropped: 1734` but no one was
   looking at that number (it was buried in the `sessions` object).

## Fix: match IRCCloud's "no-drop, cursor-based" model

The plan is 7 phases, ordered by user-visible impact:

| Phase | Component | What changes | Why |
|-------|-----------|-------------|-----|
| 1 | gateway: outbound queue | 500 → 65536 | Quick fix that prevents 99% of drops. The buffer is "effectively unbounded" for in-flight delivery. |
| 2 | gateway: cursor protocol | `header` message on connect; `ack` command from client; `lastDeliveredEid` per session; live events filtered by `eid > lastDeliveredEid` | The client explicitly tells the server "I have up to eid N". The server uses that to filter duplicate deliveries. |
| 3 | engine: persistence-first publish | Move the MongoDB write from a detached `runTask` to sync before the Redis pub/sub publish | The MongoDB scrollback is the source of truth. Events must be durable *before* the live notification, so a client that misses a frame can recover from `/api/oob` without losing the event. |
| 4 | gateway: `/api/oob` endpoint | GET `/api/oob?network=<id>&since=<eid>&count=<n>` returns events with eid > since from MongoDB | The hole-filling recovery path. The client calls this when it detects a gap in the live stream. |
| 5 | client: periodic ack | Every 5s while connected, plus on close, send `{cmd:"ack",eid:maxEid}` to the server | Feeds the `lastDeliveredEid` cursor that phase 2 reads. |
| 6 | client: hole detection | New `wsHoleDetector.ts` tracks eid sequence, calls `/api/oob` when gap > 25 | Catches the case where the WS silently dropped a frame (OS-level, not a reconnect). |
| 7 | ops: honest metrics | `/api/health` replaces `dropped`/`maxDepth` with `lastEnqueuedEid`/`lastDeliveredEid` | The old `dropped` was a *consequence* of a bug. The new fields are *signals* — the gap between them tells the operator "events are in Mongo but not on the WS" before the user notices. |

## Detailed changes

### Phase 1 — queue 500 → 65536 (`source/ircfiber/api/session.d`)

```d
// Before:
s.outbound = RingBuffer!string(500);
// After:
s.outbound = RingBuffer!string(65536);  // 3 sites
```

65536 ≈ 2500× the old size; for an active IRC user, the queue
never approaches this number. The ircPoolDispatch listener runs
concurrently with the drain, and the drain can process 100 events
per 10ms = 10,000/s, which exceeds any normal event rate.

### Phase 2 — cursor protocol (`source/ircfiber/api/session.d`, `websocket.d`)

`UserSession` gains:
```d
long sinceEid;          // initial replay filter (from ?since=)
long lastDeliveredEid;  // live event filter (from ack cmd)
long lastEnqueuedEid;   // diagnostic: highest eid put in queue
```

`SessionManager` gains:
```d
void acknowledgeEid(UUID sessionId, long eid);  // called by ack handler
```

`WebSocketGateway` gains:
- `streamId` field, set at boot
- `sendHeader()` method, called as the first WS frame
- `ack` command handler in `handleClientMessage`
- ircPoolDispatch's listener filters by `eid > max(lastDeliveredEid, sinceEid)`
  instead of just `sinceEid`

`sendHeader` envelope:
```json
{
  "type": "header",
  "streamid": "<uuid>",
  "serverId": "ovh",
  "time": 1700000000000,
  "idle_interval": 60000,
  "sinceEid": 0
}
```

`ack` payload:
```json
{ "cmd": "ack", "eid": 12345 }
```

### Phase 3 — persistence-first publish (`source/ircfiber/engine/processor.d`)

The current order is:
```
eid assignment → buffer store → Redis publish (fire) → MongoDB write (forget)
```

The new order is:
```
eid assignment → buffer store → MongoDB write (sync) → Redis publish
```

Cost: the engine's event processing slows with MongoDB latency.
Backpressure instead of data loss is the correct trade.

If MongoDB is briefly slow, `sendToSession` logs a warning and the
event is still in the Redis buffer, so the next `/api/oob` fetch
picks it up.

### Phase 4 — `/api/oob` endpoint (`source/ircfiber/api/rest.d`, `db/messages.d`)

Two new methods on `MessageRepository`:
```d
Json[] getAfterEid(string serverId, string networkId, string channel,
                   long afterEid, int count);
Json[] getAfterEidForNetwork(string serverId, string networkId,
                             long afterEid, int count);
```

Both use the existing `(serverId, networkId, channel, eid)` index
for O(log N) lookups. The endpoint is a thin HTTP wrapper that
auth-checks the user owns the network and serializes the result.

### Phase 5 — periodic ack (`frontend/src/stores/wsConnection.svelte.ts`)

```ts
setInterval(() => {
    if (maxEidTracker.value <= 0) return;
    if (ackSendInFlight) return;
    sendJson({ cmd: 'ack', eid: maxEidTracker.value });
}, 5_000);
```

Started in the WS `open` handler, stopped in `close` (and in
`disconnectWebSocket`). A final `sendFinalAck()` is fired in the
`close` handler as a best-effort final cursor.

### Phase 6 — hole detection (`frontend/src/lib/wsHoleDetector.ts`)

```ts
class HoleDetector {
    onEid(eid): void;       // track eid in sliding window
    checkForHole(): { since, to } | null;   // return gap if any
    recordFetch(): void;    // for cooldown
    start(networkId): void; // periodic check
}
```

Default: threshold 25, interval 5s, cooldown 10s. When a gap
is detected, fetchOOB() is called and the events are routed by
channel into the existing IRC state.

### Phase 7 — honest metrics (`source/ircfiber/api/session.d`, `rest.d`)

`SessionStats`:
```d
struct SessionStats {
    size_t total;
    size_t maxDepth;
    long lastEnqueuedEid;    // server trying to send
    long lastDeliveredEid;   // client ACKed
    // dropped: removed — was a lie
}
```

`/api/health.sessions`:
```json
{
  "ok": true,
  "total": 1,
  "maxDepth": 0,
  "lastEnqueuedEid": 11700,
  "lastDeliveredEid": 11650
}
```

The gap (`lastEnqueuedEid - lastDeliveredEid`) is the number of
events the server has tried to send but the client hasn't ACKed.
This is the *signal* — the old `dropped` was the *consequence*.

## Tests

D-side (`make test-fast`):
- `session-queue-test` (existing, rewritten): 72 tests covering
  the no-drop contract, `acknowledgeEid`, broadcastStats with the
  new fields, JWT round-trip, Redis persistence with the new
  fields.
- `oob-test` (new): 19 tests covering the Bson filter shape for
  `getAfterEid` / `getAfterEidForNetwork`, the Json payload
  round-trip, and the count-clamp contract.
- Other test suites (`prefs-test`, `parser-test`, etc.) untouched:
  still pass.

Frontend (`npm test`):
- `wsHoleDetector.test.ts` (new): 16 tests covering the sliding
  window, threshold/cooldown, OOB URL construction, and out-of-order
  eid handling.
- `wsConnection.ack.test.ts` (new): 6 tests covering
  `maxEidTracker` regression behavior and the ack payload contract.

## Deploy + verification

```bash
make update   # full deploy (BuildKit on remote)
# Verify on production:
curl -s http://100.126.197.92:8090/api/health | jq .sessions
# Expected: { "dropped": <removed>, "maxDepth": N, "lastEnqueuedEid": N, "lastDeliveredEid": N }
# Then trigger a reconnect and watch the page update in real-time:
#   - Phase events (queued, tcp_open, tls, registering, welcome) appear within 100ms
#   - The /api/oob endpoint works for gap filling
```

## Risk assessment

- **Phase 1** is risk-free — just a larger buffer.
- **Phase 2** adds new code paths (header send, ack handler); the
  existing `sinceEid` filter is preserved as a fallback for the
  initial WS open before the first ack arrives.
- **Phase 3** introduces a sync Mongo write on the engine hot path.
  In normal operation this is <1ms. Under MongoDB stress it could
  backpressure the engine — which is the correct trade. Existing
  Redis buffer keeps events deliverable in the meantime.
- **Phase 4** is purely additive — a new REST endpoint, no existing
  path changes.
- **Phase 5** is a small client change (5s interval, no-op for eid
  ≤ 0). One extra WS frame every 5s.
- **Phase 6** is a new client module with isolated tests; the
  detection logic is conservative (threshold 25, cooldown 10s).
- **Phase 7** removes a misleading metric. The new `lastEnqueuedEid`
  / `lastDeliveredEid` are additive.

The 1734 dropped events in `/api/health` will become 0 after phase
1. Phases 2-7 make the architecture IRCCloud-equivalent.
