# IRC Fiber — REST API

> **Source:** `backend/source/ircfiber/api/rest.d:68-118` `RESTAPI.registerRoutes` (40 endpoints), `engine/backend/source/ircfiber/web/admin/package.d:59-135` (admin API), `engine/backend/source/ircfiber/web/package.d:59-82` (web/auth).
> **Auth:** `ircfiber.auth.requireAuth` → `authenticateRequest(req, repo)` reads `connect.sid` cookie → `HGET session:<sid> sessionUserId` (`storage/session.d:13,150-156`, strip outer JSON quotes) or JWT `ws_session_jwt` fallback (`api/session.d:26-28`). `requireAdmin` guard (`admin/package.d:139-147`).
> **Serialization:** `vibe.d` `Json` with camelCase keys (`networkId`, `channel`, `prefVersion`, …). Snake case is not introduced.

## 1. Endpoints — `RESTAPI.registerRoutes` (`rest.d:68-118`) — 40 entries

| # | Method | Path | Handler | Auth | Notes |
|---|---|---|---|---|---|
| 1 | `GET` | `/api/networks` | `getNetworks` (`rest.d:122`) | session | Lists `NetworkConfig` for the calling user via `networkRepo.findByUserId` (`db/network.d:46`). Enriches each with `snap = loadSnapshot(cfg.id)` (`rest.d:131`) → `connected/status/currentNick/isAway/caps/serverId` (`rest.d:132-143`). Cache `irc:user-networks:<userId>` (`db/network.d:68`). |
| 2 | `POST` | `/api/networks` | `createNetwork` (`rest.d:149`) | session | Body `{name,host,port,tls,nick,realName,autoJoinChannels[], partedChannels[], sasl, saslUsername, saslPassword, nspass, commands, serverPass, autoJoinDelaySeconds}` (`rest.d:157-196`). `dedupChannels` (`models/network.d`), `networkRepo.save` (`db/network.d`), `del(irc:user-networks)` (`rest.d:199`). Assigns via `ServerRegistry.assignNetwork` (`irc/registry.d`) → 503 if none healthy (`rest.d:202-207`), then `LPUSH irc:control:<serverId> {action:"addNetwork"}` (`rest.d:212`). |
| 3 | `PUT` | `/api/networks/:id` | `updateNetwork` (`rest.d:217`) | session | Same fields as create, partial (`rest.d:225-263`). `getServerForNetwork` else `assignNetwork` (`rest.d:270-273`) → 503 if none (`rest.d:274-278`), `LPUSH irc:control:<serverId> {action:"updateConfig"}` (`rest.d:283`). |
| 4 | `PATCH` | `/api/networks/:id` | `updateNetwork` (alias) | session | Same handler as `PUT`. |
| 5 | `DELETE` | `/api/networks/:id` | `deleteNetwork` (`rest.d:288`) | session | Refuses `systemManaged` with 403 (`rest.d:297-303`). Captures `ownerId` (`rest.d:307`), `getServerForNetwork` (`rest.d:310`), `LPUSH irc:control:<serverId> {removeNetwork}` (`rest.d:319`) or legacy `irc:control` (`rest.d:322`), `networkRepo.deleteById` + `del(irc:user-networks)` (`rest.d:325-327`), `bufferManager.clearNetworkBuffers` (`storage/buffer.d:517/531`). |
| 6 | `GET` | `/api/channels/:network/:channel/messages` | `getMessages` | session | Two-tier: `LRANGE scrollback:<serverId>:<networkId>:<channel>` (`storage/buffer.d:134/230`, cap 5000) → Mongo `messages` fallback (`db/messages.d:510-546`, `511` key). Supports `before/after/count` cursor. |
| 7 | `POST` | `/api/networks/:network/join` | `joinChannel` | session | `IRCCommand{cmd:"JOIN"}` → `LPUSH irc:cmd:<serverId>:<network>` (`rest.d:704` + `websocket.d:1281`). Chathistory enqueue capped; defensive `HGET irc:server:<id>` for health. |
| 8 | `POST` | `/api/networks/:network/part` | `partChannel` | session | `ControlMessage action:"part"` via same control queue. |
| 9 | `POST` | `/api/networks/:id/disconnect` | `disconnectNetwork` (`rest.d:340`) | session | Body `{reason?}`. `getServerForNetwork` + `isServerHealthy` (`rest.d:360-361`), `networkRepo.setDisabled(id, true)` (`rest.d:368`), `updateDisconnectSnapshot` vs `markNetworkDisconnected` + `PUBLISH irc:events:<userId> {DISCONNECT}` synthetic (`rest.d:383-400`), `LPUSH irc:control:<serverId> {disconnectNetwork}` (`rest.d:399`). Returns `{"status":"disconnected"}`. |
| 10 | `POST` | `/api/networks/:id/reconnect` | `reconnectNetwork` (`rest.d:581`) | session | Clears `disabled` flag (`rest.d:598-601`), `LPUSH irc:control` (`rest.d:618`). |
| 11 | `POST` | `/api/networks/:id/buffers/clear` | `clearNetworkBuffer` (`rest.d:421`) | session (owner-checked) | Body `{"buffer":"<name>"}` 400 if missing (`rest.d:458`). `findByIdWithUser` owner check 403 (`rest.d:440`). `ServerRegistry.getServerForNetwork` to pick namespaced vs legacy `bufferManager.clearBuffer` (`rest.d:468-473`), Mongo `MessageRepository.deleteByChannel` (`rest.d:491-493`), 500 if Mongo fails so `clearedAt` filter stays active. Returns `{"status":"cleared",buffer,serverId}`. Powers right-click "Clear backlog" (`AGENTS.md` Janitor section). |
| 12 | `GET` | `/api/me` | `getMe` | session | Current user + `PreferencesRepository.load` → `prefVersion` + pinned/archived etc. |
| 13 | `POST` | `/api/me/pins` | `pinChannel` | session | Body `{"network","channel"}` → `prefsRepo` `pinnedChannels`. Publishes `pref_update` via `irc:events:<userId>` (`rest.d:1141`). |
| 14 | `DELETE` | `/api/me/pins/:network/:channel` | `unpinChannel` | session | Removes from `pinnedChannels`; invalidates `irc:archive-names` (`rest.d:1087`). |
| 15 | `POST` | `/api/me/archives` | `archiveChannel` | session | `archivedChannels` |
| 16 | `DELETE` | `/api/me/archives/:network/:channel` | `unarchiveChannel` | session | Invalidates `irc:archive-names` (`rest.d:1108`). |
| 17 | `POST` | `/api/me/members-collapsed` | `updateMembersCollapsed` | session | `membersCollapsed{buffer:bool}` |
| 18 | `POST` | `/api/me/conversations-collapsed` | `updateConversationsCollapsed` | session | `conversationsCollapsed` |
| 19 | `POST` | `/api/me/serverlog-collapsed` | `updateServerlogCollapsed` | session | `serverlogCollapsed` |
| 20 | `POST` | `/api/me/buffer-prefs` | `updateBufferPrefs` | session | `bufferPrefs{key:Json}` |
| 21 | `POST` | `/api/me/collapsed` | `updateCollapsed` | session | `collapsed` |
| 22 | `POST` | `/api/me/inactive-collapsed` | `updateInactiveCollapsed` | session | `inactiveCollapsed` |
| 23 | `POST` | `/api/me/network-order` | `updateNetworkOrder` | session | `networkOrder: string[]` |
| 24 | `GET` | `/api/ping` | `ping` | — | `{"ping":"pong"}` — liveness without auth. |
| 25 | `GET` | `/api/health` | `healthCheck` | — | `{healthy, mongoVersion?, redisVersion?}`. Used by compose `healthcheck` (`docker-compose.yml:36`). |
| 26 | `GET` | `/health` | `healthCheck` (alias) | — | Same handler. |
| 27 | `GET` | `/api/oob` | `getOOBEvents` (`rest.d:95-100`) | session | Query `?network=<id>&since=<eid>&count=<n>` returns events with `eid > since` from MongoDB for hole-filling when WS drops a frame. Client `wsHoleDetector` calls when gap > 25 (`plan/20260707-realtime-event-delivery`). |
| 28 | `GET` | `/api/servers` | `getServers` | session | List `ConnectionServer` via `ServerRegistry.getAllServers` (`irc/registry.d:302`); recovers from `irc:server-assignments:*` mirrors if `irc:servers` evicted. |
| 29 | `GET` | `/api/servers/:id` | `getServer` | session | `getServer(serverId)` + heartbeat status. |
| 30 | `GET` | `/api/admin/handoff/status` | `getHandoffStatus` | admin | Last handoff duration/count (`engine/handoff.d`). |
| 31 | `POST` | `/api/admin/servers/:id/clear-draining` | `clearServerDraining` | admin | Clears `HDEL irc:server:<id> draining` + `DEL irc:draining:<id>` (`irc/registry.d:252-255`). |
| 32 | `POST` | `/api/upload` | `uploadFile` | session | Multipart via `LocalUploadResult` (`upload/local.d:saveUpload`), writes to `/app/uploads`, `UploadRepository`. |
| 33 | `GET` | `/api/uploads` | `getUploads` | session | List `UploadRecord` for user. |
| 34 | `DELETE` | `/api/uploads/:id` | `deleteUpload` | session | `std.file.remove` + `UploadRepository`. |
| 35 | `GET` | `/api/pastebins` | `getPastebins` | session | `PasteRecord` list (`db/pastebins.d`). |
| 36 | `POST` | `/api/pastebins` | `createPastebin` | session | Body `{content, language?}` → `PasteRepository`, `countLines`. |
| 37 | `PUT` | `/api/pastebins/:id` | `updatePastebin` | session | |
| 38 | `DELETE` | `/api/pastebins/:id` | `deletePastebin` | session | |
| 39 | `GET` | `/api/pastebins/:id/raw` | `getPastebinRaw` | session | `text/plain`. |
| 40 | `GET` | `/api/buffers/archive-names` | `getArchiveNames` | session | Cached (`SET` `irc:archive-names:<userId>` 5-min TTL `protocol.d:127`); grouped by `networkId`. |

## 2. Admin API — `admin/package.d:59-135` (beyond `rest.d`)

All under `/api/admin/*` and gated by `adminWrap` (`requireAuth` + `requireAdmin` + `touchSessionAccess` — `admin/package.d:141-150`).

| Method | Path | Handler | Notes |
|---|---|---|---|
| `GET` | `/api/admin/me` | `apiMeRoute` | Current admin user |
| `GET` | `/api/admin/dashboard` | `apiDashboardRoute` | Totals |
| `GET` | `/api/admin/servers` | `apiServersRoute` (`admin/package.d:88`) | Same data as `/api/servers` with assignment detail |
| `GET` | `/api/admin/servers/host/:host` | `apiServerHostRoute` | |
| `POST` | `/api/admin/servers/:id/reassign` | `apiReassignServerRoute` | |
| `POST` | `/api/admin/servers/assignments/:networkId/reassign` | `apiReassignAssignmentRoute` | |
| `POST` | `/api/admin/servers/assignments/:networkId/remove` | `apiRemoveAssignmentRoute` | Clears hash field only (orphan scrub needs `delete`) |
| `POST` | `/api/admin/servers/assignments/:networkId/delete` | `apiAssignmentDeleteRoute` (`admin/package.d:93`) | Full delete: control `removeNetwork` + Mongo + Redis state (`admin/api.d:deleteNetworkCore` with `allowEmpty=true` for ghost rows) |
| `POST` | `/api/admin/servers/:id/config` | `apiEngineConfigRoute` | Per-engine `irc:engine:config:<id>` |
| `POST` | `/api/admin/servers/host/:host/disconnect/:networkId` | `apiHostDisconnectRoute` | |
| `POST` | `/api/admin/servers/host/:host/reconnect/:networkId` | `apiHostReconnectRoute` | |
| `POST` | `/api/admin/servers/host/:host/delete-network/:networkId` | `apiHostDeleteNetworkRoute` | |
| `POST` | `/api/admin/routing` | `apiRoutingRoute` | `irc:routing:config` |
| `GET/POST` | `/api/admin/users*` (6 routes) | `apiUsersListRoute`, `apiUserCreateRoute`, … | `admin/package.d:100-105` |
| `POST` | `/api/admin/sessions/clear…` (3 routes) | `apiSessionsClearRoute`, … | `admin/package.d:107-110` |
| `GET/POST` | `/api/admin/uploads*` (2 routes) | `apiUploadsListRoute`, `apiUploadDeleteRoute` | |
| `GET/POST` | `/api/admin/mongo/*` (4 routes) | `apiMongoStatusRoute`, … | `admin/package.d:115-119` |
| `GET` | `/api/admin/redis/*` (6 routes) | `apiRedisInfoRoute`, `apiRedisSummaryRoute`, … | `admin/package.d:121-128` includes `slowlog`, `pubsub`, `clients` |
| `GET/POST` | `/api/admin/janitor/*` (4 routes) | `apiJanitorStatusRoute`, `apiJanitorEventsRoute`, `apiJanitorReapRoute`, `apiJanitorCycleRoute` | `admin/package.d:130-134` (`engine_janitor.d`) |

Additionally `web/package.d:59-82` serves `GET /`, `/irc/*`, `/login`, `/register`, `/logout`, `/public/*`, `/assets/*`, `/uploads/*`, `/api/events`.

## 3. Error semantics

- Unauthenticated → `401` JSON `{error}` via `requireAuth`.
- No healthy engine on `POST /api/networks` or `PUT` → `503 {error:"No healthy connection servers available"}` (`rest.d:205,276`).
- `systemManaged` delete → `403 {error:"…provisioned…", systemManaged:true}` (`rest.d:299`).
- `clearNetworkBuffer` missing `buffer` → `400 {error:"Missing \`buffer\` field"}` (`rest.d:460`), wrong owner → `403 {error:"Not your network"}` (`rest.d:442`), Mongo purge failure → `500`.
- `ensureEngineHealthy` failure on WS is NOT a REST error — gateway synthesizes an `ERROR` `irc_event` instead (`websocket.d:1213` contract, see `docs/WS_PROTOCOL.md`).

## 4. Frontend coupling

- `frontend/src/stores/api.ts` `API_BASE = '/api'` (to become `VITE_API_BASE` env-driven in Step 3). All `fetch` go through it.
- `frontend/vite.config.ts` proxy table must keep SigNoz `/api/v1-5/` before catch-all `/api` (`AGENTS.md` Dev proxy).
- Caddy `deploy/roles/caddy/templates/Caddyfile.j2` `reverse_proxy /api/*` + `/ws` at `gateway:8090`; will become togglable `gateway_backend_host:gateway_use_python`.

## 5. Wire schemas

All bodies use `vibe.data.json.Json` (`serializeToJson`/`deserializeJson`). `NetworkConfig` (`models/network.d`) keys are camelCase; `UserPreferences` includes `prefVersion` monotonic (`PREF_VERSION.md`). `IRCRawEvent` compact JSON (`models/irc_event.d:IRCRawEvent.makeIsupport` etc.) is stored in `scrollback:` and `irc:stream:` and replayed via WS `irc_event` / `batch`.

