# IRC Fiber — Inter-Service Contract (v1)

> **Source of truth:** `common/source/ircfiber/redis/protocol.d` (and the modules it re-exports).
> **Serialization:** `vibe.d` `Json` (`vibe.data.json.Json`) — snake vs camel is NOT a factor; wire keys keep existing camelCase (`networkId`, `channel`, `reason`, `prefVersion`, …). No new envelope is introduced.
> **Version:** `PROTOCOL_VERSION = 1` — see `common/source/ircfiber/redis/protocol.d:176-181` and `RedisKeys.protocolVersion() → "irc:protocol:version"` (`protocol.d:152-156`). Stored by the engine heartbeat in `engine/source/ircfiber/engine/state.d:47-52` (`ctx.redis.getDb().set(RedisKeys.protocolVersion(), PROTOCOL_VERSION.to!string)`). Gateways SHOULD assert at startup that the stored value equals `1`; mismatch MUST surface as healthcheck failure. Not yet enforced — version `1` is the initial frozen contract.

## 1. Redis key namespace — `RedisKeys` (`protocol.d:31-174`)

All keys are strings produced by `ircfiber.redis.protocol.RedisKeys`. Every per-engine key contains the literal substring `:<serverId>:` so the janitor can `SCAN "*:<serverId>:*"` (`protocol.d:158-173`).

| Key pattern | Helper | File:line | Notes |
|---|---|---|---|
| `irc:server:<serverId>` | `RedisKeys.server(serverId)` | `protocol.d:33` | Hash `HSET` server metadata (`data`, `lastHeartbeat`, `isHealthy`, `draining`). Written by `ServerRegistry.registerServer` / `syncServerState` (`irc/registry.d:116-118, 213-215`) and heartbeated by `updateHeartbeat` (`registry.d:188-194`). |
| `irc:servers` | `RedisKeys.serverList()` | `protocol.d:35` | Set of registered server IDs (`SADD`/`SMEMBERS`). Rebuilt from mirrors if evicted (`registry.d:302-312`). |
| `irc:assignments` | `RedisKeys.networkAssignments()` | `protocol.d:37` | Canonical `HSET` networkId → serverId mapping. Primary routing table for `ServerRegistry.getServerForNetwork`. |
| `irc:server-assignments:<serverId>` | `RedisKeys.serverAssignments(serverId)` | `protocol.d:92-94` | Per-engine mirror of the canonical hash, written every heartbeat via `publishServerAssignments` (`registry.d:160-168`). Recovery source if `irc:assignments` is evicted under `allkeys-lru`. |
| `irc:server-assignments:*` | `RedisKeys.serverAssignmentsPattern()` | `protocol.d:99-101` | `SCAN` pattern used by `getAllAssignments()` to rebuild the canonical hash. |
| `irc:state:<serverId>:<networkId>` | `RedisKeys.state(serverId, networkId)` | `protocol.d:40-42` | Namespaced `NetworkStateSnapshot` JSON (`HSET data`). Written every 10 s by `engine/state.d:240-241` and on every retry/fail event via `processor.d`. Read by gateway `websocket.d:845-852` (server-aware) before falling back to legacy. TTL `StateTTL.DEFAULT` (600 s) via `engine_janitor.d:102-104`. |
| `irc:state:<networkId>` (legacy) | `RedisKeys.state_legacy(networkId)` | `protocol.d:56` | Non-namespaced fallback. Gateway tries server-aware key first, then legacy (`websocket.d:854`). Documented as deprecated but readable for one release. |
| `irc:buffer:<serverId>:<networkId>:<channel>` *(spec name)* — runtime key is `scrollback:<serverId>:<networkId>:<channel>` | `BufferManager.KEY_PREFIX = "scrollback:"` + `serverId:networkId:channel` | `protocol.d:16` comment (spec name) / `storage/buffer.d:97-98,134` (runtime) | `LIST` of `IRCRawEvent` JSON (max 5000, `LTRIM`). 30-day TTL (`buffer.d:98`). Paired `dedup:<…>` set for idempotent writes. The `irc:buffer:` name in the `protocol.d` header comment is the spec alias; the code uses `scrollback:` — both refer to the same contract. |
| `scrollback:<serverId>:<networkId>:<channel>` | `BufferManager` namespaced | `storage/buffer.d:134,207,231` | See above. |
| `scrollback:<networkId>:<channel>` (legacy) | `BufferManager` legacy | `storage/buffer.d:275,290` | Legacy non-namespaced buffer; fallback when `serverId` is empty. |
| `dedup:<serverId>:<networkId>:<channel>` | `BufferManager.DEDUP_PREFIX = "dedup:"` | `storage/buffer.d:106,484` | `SET` of dedup keys (`msgid` tag or content hash). `SADD` returns 1/0 for dedup (`buffer.d:331-341`). 30-day TTL. Legacy `dedup:<networkId>:<channel>` (`buffer.d:503`). Scanned by janitor `engine_janitor.d:104` and migrated by `tools/janitor_migrate.d:60-61`. |
| `irc:cmd:<serverId>:<networkId>` | `RedisKeys.cmd(serverId, networkId)` | `protocol.d:48-50` | `LIST` (`LPUSH`/`BLPOP`) of `IRCCommand` JSON. Per-server command queue drained by `engine/consumer.d:259`. Gateway routes via `ServerRegistry.getServerForNetwork`; legacy fallback `irc:cmd:<networkId>` (`rest.d:864-867`). |
| `irc:cmd:<networkId>` (legacy) | `RedisKeys.cmd_legacy(networkId)` | `protocol.d:58` | Legacy global command queue. |
| `irc:control:<serverId>` | `RedisKeys.control(serverId)` | `protocol.d:53` | `LIST` of `ControlMessage` JSON (add/update/remove/disconnect/reconnect). Drained by `engine/consumer.d:75` (`BLPOP 5 s`). TTL `StateTTL.CONTROL_QUEUE_TTL` (300 s) (`protocol.d:194`). Legacy `irc:control` (`protocol.d:60`). |
| `irc:control` (legacy) | `RedisKeys.control_legacy()` | `protocol.d:60` | Legacy global control queue. |
| `irc:global_eid` | `RedisKeys.globalEid()` | `protocol.d:65` | `INCR` monotonic counter for every `IRCRawEvent.eid` (`engine/processor.d:91`). Primary key for WS replay / OOB. |
| `irc:stream:<userId>` | `RedisKeys.userStream(userId)` | `protocol.d:71` | Per-user `LIST` of live event JSON (`LPUSH` + `LTRIM 0,999` — `websocket.d:871-873`, `processor.d:166-167`). Replay source for WS `replayMissedEvents` (`websocket.d:872`). Capped at 1000; gateway caps replay to 200 newest. |
| `irc:events:<userId>` | `RedisKeys.events(userId)` | `protocol.d:45` | Pub/sub channel (`PUBLISH`/`SUBSCRIBE`) for live fan-out to WebSocket sessions (`websocket.d:950-953`, `processor.d:164`). Every event is both `LPUSH`ed to `irc:stream:<userId>` and `PUBLISH`ed here. |
| `irc:lease:<networkId>` | `RedisKeys.lease(networkId)` | `protocol.d:106` | TTL auto-expiry lease for network assignment; heartbeat renews, gateway healthcheck detects orphans. |
| `irc:shutdown` | `RedisKeys.shutdownChannel()` | `protocol.d:111` | Pub/sub channel for engine graceful-shutdown announcements (`engine/app_engine.d:174-175`, `web/app.d:431`). Gateway reassigns instantly on message. |
| `__keyspace@0__:irc:server:*` | `RedisKeys.serverKeyspacePattern()` | `protocol.d:117` | Keyspace notification pattern for server-key deletion (crash/manual cleanup). Requires `notify-keyspace-events K$`. |
| `irc:draining:<serverId>` | `RedisKeys.draining(serverId)` | `protocol.d:123` | Separate `SET` flag with 60 s TTL during SCM_RIGHTS handoff (`engine/reload_orchestrator.d:460-461`). Heartbeat clears via `registry.d:198-199`. |
| `irc:archive-names:<userId>` | `RedisKeys.archiveNames(userId)` | `protocol.d:127` | `SET`-backed cache for `GET /api/buffers/archive-names` (5-min TTL). Invalidated on pin/archive (`rest.d:1087,1108`). |
| `irc:user-networks:<userId>` | `RedisKeys.userNetworks(userId)` | `protocol.d:132` | Cached JSON array of `NetworkConfig` per user (`db/network.d:46-68`, TTL 60 s). Invalidated on create/update/delete (`rest.d:199,267,327`). |
| `irc:nick:<networkId>` | `RedisKeys.networkNick(networkId)` | `protocol.d:140` | Last successfully negotiated IRC nick (`irc/connection.d:1047-1048`). No TTL; persists until user changes nick or admin clears. Used to avoid `433` on reconnect. |
| `irc:janitor:lock` | `RedisKeys.janitorLock()` | `protocol.d:146` | Distributed lock (`SET NX EX 30`) held by elected janitor (`irc/engine_janitor.d:210-211`). `StateTTL.JANITOR_LOCK_DEFAULT = 30` (`protocol.d:186`). |
| `irc:janitor:events` | `RedisKeys.janitorEvents()` | `protocol.d:150` | `LIST` (`LPUSH`/`LTRIM 1000`) of janitor audit events (`engine_janitor.d:333-334`), read by `GET /api/admin/janitor/events`. |
| `*:<serverId>:*` | `RedisKeys.serverNamespacePattern(serverId)` | `protocol.d:158-160` | `SCAN` pattern for every per-engine key containing `:<serverId>:` — used by janitor reap and bootstrap purge (`engine_janitor.d:102-105`). Convention: new namespaced keys MUST follow this pattern. |
| `irc:protocol:version` | `RedisKeys.protocolVersion()` | `protocol.d:152-156` | Current `PROTOCOL_VERSION` value as string (`"1"`). Written by `engine/state.d:48-50` on every snapshot cycle. Not yet enforced. |
| `irc:session:<id>:ack` | (no helper — inline `"irc:session:" ~ id ~ ":ack"`) | `websocket.d:306-309,206-218` | Per-WS-session `SET`/`GET` of `lastDeliveredEid` (TTL 86400). Survives gateway restarts; on reconnect the session restores `lastDeliveredEid` (`websocket.d:211-217`) and filters live events (`ircPoolDispatch`). `EXPIRE 86400` on persist (`websocket.d:309`). |
| `session:<sid>` | `SESSION_KEY_PREFIX = "session:"` | `storage/session.d:13` | `HASH` of session fields (`HSET`-per-field, JSON-encoded values). `TTL_SECONDS = 14*24*60*60` (14 days) (`storage/session.d:30`), refreshed on every `get`/`set`/`open` (`session.d:119,142`). Fields: `sessionUserId` (JSON-quoted UUID string — outer quotes must be stripped), `ws_session_jwt`, `_created`, `lastAccess`, plus arbitrary `Variant` values. See `storage/session.d:129-146` for encoding. Legacy `ws_session:<id>` (`api/session.d:26`) also exists with same TTL (`api/session.d:28`). |
| `prefs:<userId>` | `PreferencesRepository.KEY_PREFIX = "prefs:"` | `db/preferences.d:269,371` | `HASH` of user preferences JSON; `prefVersion` monotonic counter for last-write-wins (`PREF_VERSION.md`). |
| `irc:routing:config` | `RedisKeys.routingConfig()` | `protocol.d:74` | Global routing config (per-host max connections, etc.). |
| `irc:engine:config:<serverId>` | `RedisKeys.engineConfig(serverId)` | `protocol.d:77` | Per-engine override (`priority`, `fallbackOnly`, `maxConnections`) synced to Redis every heartbeat (`registry.d:213-215`). |
| `irc:banned:<networkId>` | `RedisKeys.bannedNetwork(networkId)` | `protocol.d:80` | Admin Z-Line flag. |
| `irc:network-fail:<networkId>` | `RedisKeys.networkFail(networkId)` | `protocol.d:85` | `HASH` `{serverId, error, count, lastFailure}` for smart reassignment. TTL `NETWORK_FAIL_TTL = 24*3600` (`protocol.d:190`). |
| `irc:stream:<userId>` trim | — | `processor.d:167` | `LTRIM 0,999` on every publish. |
| `irc:control:<serverId>` TTL bump | — | `engine_janitor.d:135` | `EXPIRE 300` (`CONTROL_QUEUE_TTL`) every heartbeat. |

**Legacy fallback rule (one release):** new API MUST try the server-aware key first (`irc:state:<serverId>:<networkId>`, `irc:cmd:<serverId>:<networkId>`, `scrollback:<serverId>:<networkId>:<channel>`) then fall back to the legacy non-namespaced key (`irc:state:<networkId>`, `irc:cmd:<networkId>`, `scrollback:<networkId>:<channel>`). See `websocket.d:845-855` and `rest.d:864-868`.

## 2. TTL constants — `StateTTL` (`protocol.d:183-195`)

| Constant | Value | Env override | Notes |
|---|---|---|---|
| `StateTTL.DEFAULT` | `600` s | `IRCFIBER_STATE_TTL` (60–86400) | Default for `irc:state:<server>:<network>`. Heartbeat bumps every 10 s → 60× slack. |
| `StateTTL.JANITOR_INTERVAL_DEFAULT` | `60` s | `IRCFIBER_JANITOR_INTERVAL` (5–3600) | Gateway janitor cadence (`engine_janitor.d`). |
| `StateTTL.JANITOR_LOCK_DEFAULT` | `30` s | `IRCFIBER_JANITOR_LOCK_TTL` (5–300) | `irc:janitor:lock` `SET NX EX`. |
| `StateTTL.NETWORK_FAIL_TTL` | `86400` s (24 h) | — | `irc:network-fail:<network>`. |
| `StateTTL.CONTROL_QUEUE_TTL` | `300` s | — | `irc:control:<server>` bumped every heartbeat. |
| `BufferManager.TTL_DAYS` | `30` d (`30*86400`) | — | `scrollback:` + `dedup:` (`storage/buffer.d:98,108`). |
| `RedisSessionStore.TTL_SECONDS` | `1209600` s (14 d) | — | `session:<sid>` (`storage/session.d:30`). |
| `irc:session:<id>:ack` | `86400` s (1 d) | — | `websocket.d:309`. |
| `irc:stream:<userId>` | `1000` entries (`LTRIM`) | — | Bounded live stream. |
| `irc:stream:<userId>` replay cap | `200` events | — | WS `replayMissedEvents` (`websocket.d:873` comment). |

Invalid env values fall back to defaults with `WARN` at startup (`AGENTS.md` Env knobs).

## 3. `NetworkStateSnapshot` (`protocol.d:348-560`)

JSON envelope stored at `irc:state:<serverId>:<networkId>` `data` field (`engine/state.d:241`). Produced by `engine/state.d:63-245` and consumed by `api/websocket.d:444-530` (`performStateDump`) and `api/rest.d:131-136` (`loadSnapshot`). See `protocol.d:417-474` (`toJson`) and `protocol.d:477-559` (`fromJson`) for exact wire shape.

| Field | JSON key | Type | Present? | Notes |
|---|---|---|---|---|
| `config` | `config` | `Json` (NetworkConfig) | optional | Full network config (`host`, `port`, `tls`, `nick`, `realName`, `autoJoinChannels`, …). |
| `connected` | `connected` | `bool` | always | |
| `status` | `status` | `string` | always | `queued` / `connecting` / `connected` / `disconnected` / `waiting_to_retry` etc. |
| `currentNick` | `currentNick` | `string` | always | Effective nick (negotiated or `config.nick`). |
| `buffers` | `buffers` | `Json[]` | optional | Server + channel + query buffers. |
| `topics` | `topics` | `Json[string]` | optional | `channel → topic` |
| `users` | `users` | `Json[string]` (string[]) | optional | `channel → nicks[]` (may carry prefix / hostmask) |
| `realnames` | `realnames` | `Json[string]` | optional | `bareNick → realname` (IRCCloud-style) |
| `accounts` | `accounts` | `Json[string]` | optional | `bareNick → account` (extended-join) |
| `idents` | `idents` | `Json[string]` | optional | `bareNick → ident` (userhost-in-names) |
| `ownerId` | `ownerId` | `string` (UUID) | optional | |
| `serverId` | `serverId` | `string` | optional | Attributing engine (`engine/state.d:83`). |
| `isAway` | `isAway` | `bool` | always | From `PersistentIRCClient.getIsAway`. |
| `awayMessage` | `awayMessage` | `string` | if set | From `getAwayMessage`. |
| `updatedAt` | `updatedAt` | `long` (unix-ms) | always | |
| `caps` | `caps` | `string[]` | if non-empty | Negotiated IRCv3 caps. |
| `isupport` | `isupport` | `Json[string]` (string→string) | always ( `{}` when empty) | Full 005 inventory upper-cased (`engine/state.d:178-180`). |
| `partedChannels` | `partedChannels` | `string[]` | if non-empty | Inactive channels (see `AGENTS.md` clear-backlog). |
| `retryStatus` | `retryStatus` | `{attemptCount,nextRetryAtMs,delayMs}` | iff `hasRetryStatus` | `RetryStatus` (`protocol.d:289-309`). Omitted when `hasRetryStatus==false` (`protocol.d:463-464`). |
| `failInfo` | `failInfo` | `{type,reason,killedReason,sslVerifyError?}` | iff populated | `FailInfoSnapshot` (`protocol.d:319-345`). Omitted when empty (`protocol.d:466-472`). |
| `hasRetryStatus` | (not serialized — flag) | `bool` | internal | Controls whether `retryStatus` is emitted. |

`fromJson` is backward-compatible: missing `isupport` → empty map, missing `retryStatus` → `hasRetryStatus=false`, missing `failInfo` → empty.

### 3.1 `RetryStatus` (`protocol.d:289-309`)

```
{ "attemptCount": int, "nextRetryAtMs": long, "delayMs": long }
```

Mirrors `ircfiber.irc.connection.RetryStatus` and the `CONNECTION_RETRY_STATUS` event `rs` payload.

### 3.2 `FailInfoSnapshot` (`protocol.d:319-345`)

```
{ "type": string, "reason": string, "killedReason": string, "sslVerifyError"?: { "type": string, "error": string } }
```

Mirrors `CONNECTION_FAIL` `fi` payload. `type` ∈ `connecting_failed` | `killed` | `socket_closed` | `ssl_verify_error` | `connecting_restricted` | `connection_blocked`.

## 4. Command envelopes

### 4.1 `IRCCommand` (`protocol.d:197-239`)

```
{ "cmd": string, "target"?: string, "text"?: string, "channel"?: string, "userId"?: string, "timestampMs": long, "label"?: string }
```

Pushed via `LPUSH irc:cmd:<serverId>:<networkId>` (`rest.d:865-867`, `websocket.d:1281-1284`). Consumed by `engine/consumer.d:259`.

### 4.2 `ControlMessage` (`protocol.d:241-283`)

```
{ "action": string, "networkId"?: string, "userId"?: string, "config"?: Json, "channel"?: string, "reason"?: string, "timestampMs": long }
```

`action` ∈ `addNetwork` | `updateConfig` | `removeNetwork` | `disconnectNetwork` | `reconnectNetwork` | `gracefulReload` + channel `join`/`part` variants. Pushed via `LPUSH irc:control:<serverId>` (`rest.d:212,283,319,399,618`). Drained by `engine/consumer.d:75`.

Wire format is `vibe.data.json.Json` (`toJson().toString()`). Both sides use `parseJsonString` / `fromJson`.

## 5. Session & auth boundary

- `RedisSessionStore` (`storage/session.d:24-254`): `SESSION_KEY_PREFIX = "session:"` (`session.d:13`), `TTL_SECONDS = 14*24*60*60` (`session.d:30`), `MAX_SESSIONS_PER_USER = 10` (`session.d:14`). `HSET session:<sid> <field> <json-encoded-value>` where values are `serializeToJson` strings (e.g. `'"<uuid>"'` — outer quotes must be stripped on read, see `storage/session.d:284-285`, `admin/sessions.d:54`). `connect.sid` cookie (`httpOnly|secure`), `SessionOption.httpOnly|secure` (`app.d:141`). JWT fallback `ws_session_jwt` field + `WS_SESSION_KEY_PREFIX = "ws_session:"` (`api/session.d:26`, TTL 14 d `api/session.d:27`) for WebSocket resume — see `docs/WS_PROTOCOL.md`.
- Python MUST read the same `session:<sid>` hash and decode `sessionUserId` (`req.session.get("sessionUserId")` path in `auth.d:authenticateRequest`). Fallback to JWT `verifySessionJWT` (`api/session.d`) remains as escape hatch.

## 6. Versa

- Redis: `IRCfIBER_REDIS_URL` / `VITE_REDIS_URL` etc.; gateway and engine share only `redis` + `mongo` + `ircfiber_net` (`docker-compose.yml`, `deploy/local/docker-compose.yml`).
- Mongo: `users`, `networks` (with `userId` foreign key), `messages`, `preferences`, `uploads`, `pastebins` collections (`db/*`).
- `NetworkConfig` serialized via `toJson()` / `fromJson()` (`models/network.d`); `dedupChannels` normalizes `#` lower-case.

## 7. Verification

```
grep -rn RedisKeys engine/source/       # no new key usages after Step 0
md5sum common/source/ircfiber/redis/protocol.d
```

Footer checksum (frozen at contract freeze):

```
protocol.d md5: 997afa8ef22c06d5e9f00ce17477793f
```

*If this file diverges from `protocol.d`, the `md5sum` check fails — update `docs/CONTRACT.md` and bump `PROTOCOL_VERSION` together.*

