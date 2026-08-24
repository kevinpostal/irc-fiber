# IRC Fiber — WebSocket Protocol

> **Source:** `backend/source/ircfiber/api/websocket.d:122-1285` — `WebSocketGateway` (`websocket.d:75-318`)
> **Transport:** `GET /ws?since=<maxEid>&streamid=<streamId>` upgraded to `WebSocket` via `vibe.http.websockets` (`app.d:160-162`). Auth via `authenticateRequest(socket.request, repo)` reading `connect.sid` cookie → `RedisSessionStore` `session:<sid>` or JWT `ws_session_jwt` (`websocket.d:104-165`). Idle interval negotiated in `header` (`websocket.d:330-344`).

## 1. Handshake & `ensureEngineHealthy` gate (`websocket.d:1213` comment / `websocket.d:845`)

On WS open `handleWebSocket` (`websocket.d:103-318`):
1. `authenticateRequest` — if `user.username.length==0` → `socket.close(1008,"Invalid token")`.
2. Session resume: if `req.session.get("ws_session_jwt")` exists and `sessionManager.getSession(sessionId) is null`, restore from Redis (`sessionManager.restoreFromRedis` — cold path, `websocket.d:138-150`); else if still live → new tab → fresh session (`websocket.d:152-158`).
3. Parse `?since=<eid>` (`websocket.d:198-200`), restore `lastDeliveredEid` from `GET irc:session:<id>:ack` (`websocket.d:210-218`).
4. Send `header` (`websocket.d:330-344`), `stat_user` (`websocket.d:351-400`), `networks` (`websocket.d:408-423`), `sync` (`websocket.d:425-803`) in that order — all via direct `socket.send` before the async listener starts.
5. `replayMissedEvents` (`websocket.d:870-930`) — `LRANGE irc:stream:<userId> 0 -1`, filter `eid > sinceEid`, send up to **200** newest before advancing `sinceEid` (`websocket.d:873-875` comment, cap in replay).
6. Subscribe to `irc:events:<userId>` (`websocket.d:949-953` → `startIrcEventListenerOnPool`) and start `drainOutboundLoop` batcher (`websocket.d:261-270`) + `enterUpdateLoop` (`websocket.d:271`).

### `ensureEngineHealthy` gate

Before forwarding any `IRCCommand`/`ControlMessage` that targets an engine (`websocket.d:1280-1285`, `rest.d:361-362`), the gateway checks `ServerRegistry.isServerHealthy(serverId)` → `HGET irc:server:<id> data` + `lastHeartbeat` staleness. If no healthy engine, the gateway (and future Python) MUST emit a synthetic pseudo-`ERROR` `irc_event` so the frontend shows "engine offline" without API shape drift. Python MUST preserve this semantic (see `docs/CONTRACT.md` edge handling).

## 2. Server → Client frames (JSON `type`)

| `type` | Source | Shape | Notes |
|---|---|---|---|
| `header` | `websocket.d:330-344` `sendHeader` | `{type:"header", streamid, serverId:"ovh", time (unix-ms), idle_interval:60000, sinceEid}` | Very first frame. `streamid = randomUUID()` per gateway instance (`websocket.d:95`). Client bakes `streamid` into next `?since=` reconnect. `idle_interval` tells client when to consider stream dead. |
| `stat_user` | `websocket.d:351-400` `sendStatUser` | `{type:"stat_user", t, username, email, pinnedChannels[], archivedChannels[], serverlogCollapsed{}, membersCollapsed{}, collapsed{}, inactiveCollapsed{}, conversationsCollapsed{}, networkOrder[], bufferPrefs{}, prefVersion}` | `UserPreferences` snapshot (`db/preferences.d`). Single MongoDB + Redis load reused across `stat_user`/`networks`/`sync` (`websocket.d:236-237`). `prefVersion` monotonic last-write-wins tiebreaker (`PREF_VERSION.md`). |
| `networks` | `websocket.d:408-423` `sendNetworkList` | `{type:"networks", t, items:[{networkId,name}]}` | Lightweight sidebar list before full `sync`. |
| `sync` | `websocket.d:425-803` `performStateDump` | `{type:"sync", t, sequence:0, phases:{start,prefs,…}, networks:[{…NetworkStateSnapshot…}], buffersToDelete?}` | Full dump. `netObj` mirrors `REST GET /api/networks` + `NetworkStateSnapshot` expansion (`websocket.d:449-546`). Includes `buffers[]` with `topic/users/realnames/accounts/idents/isPinned`, `channelUsersMap` (`websocket.d:792-798`), `retryStatus` (`websocket.d:522-524`) and `failInfo` (`websocket.d:533-534`) when present, `isupport` (`websocket.d:501-504`), `realnames/accounts/idents` (`websocket.d:470-492`). Yield every 50 buffers (`websocket.d:724-728`). `buffersToDelete` present only on resume (`sinceEid>0`) for ghost-channel GC (`websocket.d:446-447`). |
| `irc_event` | `websocket.d:870+` replay + `engine/processor.d:163-167` live | `{type:"irc_event" (or "batch" envelope), eid (monotonic via INCR irc:global_eid), y:"irc_event", network, channel, nick, text, command, …}` | **Replay:** `LRANGE irc:stream:<userId>` filtered `eid > sinceEid`, capped 200 (`websocket.d:871-875`). Advances `sinceEid`. **Live:** `PUBLISH irc:events:<userId>` → subscriber → `sendToSession` → `drainOutboundBatch` groups up to 100 events or 10 ms window into single `batch` frame (`websocket.d:262-267`). Single events sent as single `irc_event`. `ack` cursor filtering via `lastDeliveredEid` (`websocket.d:205-218`, `ircPoolDispatch`). |
| `batch` | `websocket.d:261-270` `drainOutboundLoop` | `{type:"batch", events:[irc_event…]}` | Envelope for grouped live events (≤100, ≤10 ms). |
| `ERROR` (pseudo `irc_event`) | `websocket.d:1213` gate + `rest.d:202-207` | `{type:"irc_event", y:"irc_event", command:"ERROR", text:"engine offline"}`-like | Synthesized when `ensureEngineHealthy` finds zero healthy servers. Frontend renders as banner without API shape drift. Must be preserved in Python (`docs/CONTRACT.md` Edge handling). |
| `pref_update` | `rest.d:1141` / admin prefs | `{type:"pref_update", prefVersion, …prefs}` | Published via `PUBLISH irc:events:<userId>` on every `PreferencesRepository.save` so other tabs/devices see canonical `prefVersion` in real time (`PREF_VERSION.md:15`). |

All outbound frames are `sanitizeUtf8(msg.toString())` (`websocket.d:340,399,422`).

## 3. Client → Server messages (`handleClientMessage` — `websocket.d:1050+`)

JSON `cmd` dispatched in `handleClientMessage`. File:line anchors are approximate (see `websocket.d:122-1285`):

| `cmd` | Payload fields | Server action |
|---|---|---|
| `ack` | `{cmd:"ack", eid: long}` | `session.lastDeliveredEid = max(eid, current)` and `SET irc:session:<id>:ack eid` + `EXPIRE 86400` (`websocket.d:305-309`). Filters live replay (`lastDeliveredEid < eid`). Client sends every 5 s + on close. |
| `sync` | `{cmd:"sync"}` | Re-run `performStateDump` for the requesting session (no-eid-range sync). |
| `buffer` | `{cmd:"buffer", network, channel?, count?, before?, after?}` | `GET /api/channels/:network/:channel/messages` via Redis `scrollback:<serverId>:<networkId>:<channel>` + Mongo fallback (`storage/buffer.d` + `db/messages.d`). |
| `msg` | `{cmd:"msg", network, target, text, label?}` | Build `IRCCommand{cmd:"PRIVMSG"}` → `LPUSH irc:cmd:<serverId>:<network>` (`websocket.d:1281`). Label for IRCv3 `labeled-response`. |
| `editmsg` | `{cmd:"editmsg", network, target, text}` | `IRCCommand` with `cmd` for message edit (IRCv3 `draft/edit`). Same queue. |
| `join` | `{cmd:"join", network, channel}` | `ControlMessage action:"join"` → `LPUSH irc:control:<serverId>` (`websocket.d:1281` path via `handleClientMessage`). |
| `part` | `{cmd:"part", network, channel, reason?}` | Same control queue `action:"part"`. |
| `raw` | `{cmd:"raw", network, text}` | Raw IRC line → `IRCCommand{cmd: text}` → command queue. |

Unknown `cmd` is ignored (no `ERROR` reply). Heavy handlers run via `g_ircPool` for OS-thread isolation (`websocket.d:34-44`).

## 4. ACK cursor contract

- Per-session cursor key `irc:session:<id>:ack` (`"irc:session:" ~ session.id ~ ":ack"`) — `SET` on `ack` (`websocket.d:308`) and on `destroy` (`websocket.d:308` in `finally`), `GET` on next `handleWebSocket` entry (`websocket.d:211`) + `session.sinceEid` (`?since=<maxEid>`) from query string (`websocket.d:198`).
- Live dispatch (`ircPoolDispatch`) drops any `eid ≤ lastDeliveredEid`. Replay via `LRANGE irc:stream:<userId>` also filters by `sinceEid` (`websocket.d:872-875`).
- TTL 86400 (`websocket.d:309`) — GC for gone users. OOB fallback `GET /api/oob?since=<eid>` covers the rare missed-eid hole (`rest.d:95-100`, `plan/20260707-realtime-event-delivery/plan-summary.md`).
- Frontend `wsConnection.svelte.ts` `maxEidTracker` + `ack` every 5 s + `holeDetection` calls `/api/oob` when gap > 25 (`AGENTS.md` Testing Guide).

## 5. Frontend coupling

- `frontend/src/stores/wsConnection.svelte.ts` owns `sinceEid`/`streamid` and reconnect backoff; `frontend/src/stores/api.ts` centralizes `API_BASE = '/api'` (to become `VITE_API_BASE` env-driven in Step 3).
- Vite dev proxy `frontend/vite.config.ts` must keep SigNoz `/api/v1-5/` rules BEFORE the catch-all `/api` → gateway rule (see `AGENTS.md` Dev proxy).
- Caddy `deploy/roles/caddy/templates/Caddyfile.j2` `reverse_proxy` for `/api/*` + `/ws` at `gateway:8090`; togglable to `irc-fiber-api-py:8000` via `gateway_backend_host`/`gateway_use_python` in Step 3.
