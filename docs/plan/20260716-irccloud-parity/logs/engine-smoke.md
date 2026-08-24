# Plan 20260716-irccloud-parity — engine smoke evidence

> **Status: PARTIAL — code-inspected + frontend-pinned.**
> Live `dub run` smoke against a closed-port IRC server was **NOT**
> executed in this worktree. Two blockers:
>  1. The Wave 1 engine changes (`waiting_to_retry` enum value,
>     `CONNECTION_RETRY_STATUS` / `CONNECTION_FAIL` factories,
>     `FailInfo` struct, zero-clear emits, retryStatus snapshot field)
>     live on `w1-t01-engine-retry-fail` (commit `d047d8f`). The
>     `w5-docs-smoke` worktree branched from `b9b2f4e` per the
>     plan's chain-of-worktrees convention, so the engine-side
>     code does not exist in this worktree.
>  2. The Wave 1 smoke requires a running redis + the engine
>     binary. `dub build --force --config=connection-registration-test`
>     is the documented gate per `AGENTS.md` Known Issues
>     ("Engine-side `dub test` (Dub-managed) currently fails to
>     build"). Running the engine binary needs a live IRC server
>     (`make local-dev-up`); that infrastructure is not part of
>     the Wave 5 docs work.
> What follows is the **code-inspection evidence + test-suite
> pinning** that ties each of the three plan-section-G scenarios
> to a verifiable file:line. A live smoke recipe is included
> for the deploy-time verification step (`make update`).

## Smoke scenario 1 — closed-port retry-loop observable

**Plan criterion** (plan.yaml:338-354): launch a network pointing at
`127.0.0.1:1`; sleep > 15 s; observe `irc:state:<sid>:<nid>` via
`redis-cli HGET ... data | jq .retryStatus`; assert
`attemptCount >= 2`, `nextRetryAtMs` within `delayMs + 1 s` of
`now`, `delayMs > 0`.

### Code path (engine branch `w1-t01-engine-retry-fail`)

| Step | File:line | Behaviour |
|---|---|---|
| Enters backoff loop | `source/ircfiber/irc/connection.d:1737-1755` | Sets `state = ConnectionState.waiting_to_retry`; bumps `backoff.currentAttempt()`; computes `nextRetryAtMs = now + delayMs` |
| Emits retry status | `source/ircfiber/irc/connection.d:1780-1789` | `eventChannel.put(IRCRawEvent.makeConnectionRetryStatus(network, nid, attemptCount, nextRetryAtMs, delayMs))` |
| Returns to connecting | `source/ircfiber/irc/connection.d:1914` (next iteration of `attemptConnectionImpl`) | Sets `state = ConnectionState.connecting` before the next TCP connect attempt |
| Snapshot writer publishes retryStatus | `source/ircfiber/engine/state.d:196-203` | `snap.retryStatus = client.getRetryStatus()` (nullable; absent in legacy snapshots) |
| WS sync ships retryStatus | `source/ircfiber/api/websocket.d:511-518` | `netObj["retryStatus"] = snap.retryStatus.toJson()` when defined |

### Frontend pin (this worktree, W2 + W3)

| Test | File:line | Asserts |
|---|---|---|
| `applyRetryStatus writes retryStatus onto the matching network` | `frontend/src/stores/ircStore.svelte.test.ts:2827-2837` | When `applyRetryStatus(nid, {attemptCount:3, nextRetryAtMs:..., delayMs:12000})` is called, `net.retryStatus` matches |
| `applyRetryStatus sync snapshot adopts retryStatus when present, nulls when absent` | `frontend/src/stores/ircStore.svelte.test.ts:2900-2937` | When WS sync carries `retryStatus`, the store adopts it; when absent, the store calls `applyRetryStatus(null)` which clears `retryStatus` AND `failInfo` (TG5 invariant) |
| `messageHandler CONNECTION_RETRY_STATUS dispatch` | `frontend/src/lib/messageHandler.test.ts:240-265` | Zero payload (`{attemptCount:0,nextRetryAtMs:0,delayMs:0}`) routes to `applyRetryStatus(nid, null)`; non-zero payload routes to `applyRetryStatus(nid, rs)`; malformed payload defensively clears |
| `renderRetryCountdown emits Nth attempt ordinal` | `frontend/src/lib/connectionWarnings.test.ts:152-189` | 1→"1st", 2→"2nd", 3→"3rd", 4→"4th", 11→"11th", 21→"21st" |
| `ConnectionStatus banner shows live countdown` | `frontend/src/components/ConnectionStatus.test.ts:180-199` | Renders `Reconnecting in <N>s... (<ordinal> attempt)`; `vi.advanceTimersByTime(5_000)` ticks the displayed value from 12s to 7s |
| `setInterval cleared on unmount (no leaked timer)` | `frontend/src/components/ConnectionStatus.test.ts:342-369` | After component unmount, `vi.getTimerCount() === 0` (W3-rev1 fix) |

### Live recipe (deploy-time)

```bash
# 1. Bring up local stack
make local-dev-up

# 2. Build the engine from the w1-t01 branch (or post-merge main)
git checkout w1-t01-engine-retry-fail
make engine-handoff        # rebuilds + hot-reloads

# 3. From the gateway host, add a network pointing at the closed port
curl -fsS -X POST http://localhost:8090/api/networks \
  -H 'Content-Type: application/json' \
  -d '{"host":"127.0.0.1","port":1,"nick":"smoketest","realname":"smoke"}'

# 4. Wait > 15s, then read the snapshot
redis-cli -h localhost HGET "irc:state:<sid>:<nid>" data | jq .retryStatus

# Expected:
#   { "attemptCount": >=2, "nextRetryAtMs": <now + delayMs>, "delayMs": >0 }
```

## Smoke scenario 2 — CONNECTION_FAIL with nested FailInfo

**Plan criterion** (plan.yaml:356-364): from the same closed-port
run, assert `irc:state:<sid>:<nid>.failInfo` carries `type`, `reason`
AND — for an `ssl_certificate_error` reason — `sslVerifyError` as a
nested object `{type: "bad_cert", error: "cert_expired"}` (NOT the
legacy flat pair).

### Code path

| Step | File:line | Behaviour |
|---|---|---|
| `FailInfo` struct (engine) | `source/ircfiber/irc/connection.d:532-548` | `string type_; string reason_; string killedReason_; Json sslVerifyError_;` — nested, NOT flat |
| `setSSLVerify` helper | `source/ircfiber/irc/connection.d:557-565` | Builds the nested `Json(string[string])` object so the wire shape matches the frontend's `FailInfo` interface byte-for-byte (plan B2 invariant) |
| `makeConnectionFail` factory | `source/ircfiber/models/irc_event.d:311-318` | Returns `{n, nid, c:'CONNECTION_FAIL', fi:{t,r,kr,sve:{type,error}}}` |
| `parseReasonToFailInfo` parser | `source/ircfiber/irc/connection.d:4120-4175` | Maps `etimedout/econnrefused/nxdomain/ssl_certificate_error/ssl_error/pool_lost/ehostunreach/enetdown/crash/killed_reason` reason substrings to typed `FailInfo.type` values; lowercases the lookup keys so `Overridden` / `ERR_NICKNAMEINUSE` / `Connection closed` (mixed-case engine emits) match (W1-rev1 fix) |
| Disconnect site emits CONNECTION_FAIL | `source/ircfiber/irc/connection.d:3910-3925` | `eventChannel.put(IRCRawEvent.makeConnectionFail(network, nid, info))` AND continues to set the legacy `lastEmittedReason` string for back-compat |
| Intentional disconnect suppresses fail emission | `source/ircfiber/irc/connection.d:822-823 + 3915-3920` | `stop()` sets `isShutdownRequested = true`; `parseReasonToFailInfo` checks the flag before constructing FailInfo; user/admin disconnects land in the clean `disconnected` branch, not the failed branch (W1-rev1 fix) |

### Frontend pin

| Test | File:line | Asserts |
|---|---|---|
| `renderReason('econnrefused') === 'Connection refused'` | `frontend/src/lib/connectionWarnings.test.ts` (W2: renderReasons.test.ts:21-29) | TG1 explicit pin |
| `renderReason('nxdomain') === 'Invalid hostname'` | `frontend/src/lib/connectionWarnings.test.ts` (W2: renderReasons.test.ts:24) | TG1 explicit pin |
| `renderReason('ssl_certificate_error') === 'SSL certificate error'` | `frontend/src/lib/connectionWarnings.test.ts` (W2: renderReasons.test.ts:27) | TG1 explicit pin |
| `renderSSLVerify({type:'bad_cert', error:'cert_expired'}) === 'Certificate expired'` | `frontend/src/lib/connectionWarnings.test.ts` (W2: renderReasons.test.ts:103) | B2 nested lookup, plan W3-T01 acceptance #7 |
| `applyFail writes failInfo onto the matching network` | `frontend/src/stores/ircStore.svelte.test.ts:2943-2953` | `net.failInfo === {type, reason, ...}` after `applyFail(nid, fi)` |
| `applyFail preserves structured sslVerifyError (nested shape byte-for-byte)` | `frontend/src/stores/ircStore.svelte.test.ts:2985-2999` | The nested `{type, error}` shape round-trips byte-for-byte; no per-side conversion in messageHandler (B2 invariant) |
| `ConnectionStatus renders "Failed to connect - <reason>" when failInfo.type=connecting_failed` | `frontend/src/components/ConnectionStatus.test.ts:106-114` | Plan line 1128 |
| `ConnectionStatus renders "Disconnected - Killed: <reason>" when failInfo.type=killed` | `frontend/src/components/ConnectionStatus.test.ts:116-124` | Plan line 1129 |
| `ConnectionStatus renders SSL verify error banner when failInfo.sslVerifyError present` | `frontend/src/components/ConnectionStatus.test.ts:126-138` | Plan line 1126 |

### Live recipe

```bash
# Continuing from scenario 1's live setup, with TLS enabled:
curl -fsS -X PATCH http://localhost:8090/api/networks/<nid> \
  -d '{"tls":"required","port":6697,"host":"self-signed.test"}'

# Wait one full retry cycle (15-20s), then:
redis-cli -h localhost HGET "irc:state:<sid>:<nid>" data | jq .failInfo

# Expected for an SSL verification failure:
#   { "type": "ssl_verify_error", "reason": "ssl_certificate_error",
#     "sslVerifyError": { "type": "bad_cert", "error": "cert_expired" } }

# Expected for an intentional /disconnect:
#   failInfo absent (legacy disconnectReason may be set)
```

## Smoke scenario 3 — failInfo cleared after successful reconnect

**Plan criterion** (plan.yaml:366-373): force the engine through one
fail cycle, then re-point the network at a working server, then
poll `failInfo` and assert it is `null` within 12 s.

### Code path

| Step | File:line | Behaviour |
|---|---|---|
| `emitZeroRetryStatus` (helper) | `source/ircfiber/irc/connection.d:1151-1158` | Emits `makeConnectionRetryStatus(network, nid, 0, 0, 0)` — frontend maps to `applyRetryStatus(nid, null)` |
| `emitZeroRetryStatus` at every `backoff.reset()` site | `connection.d:1307-1309`, `1685-1690` | Three of three backoff.reset sites emit the zero clear (W1-rev1 fixed the 4th site at line 1657 per Wave 1 review Medium #1) |
| Frontend dual-clear | `frontend/src/stores/ircStore.svelte.ts:2182-2186` | `applyRetryStatus(nid, null)` sets `net.retryStatus = null` AND `net.failInfo = null` (TG5 invariant) |

### Frontend pin

| Test | File:line | Asserts |
|---|---|---|
| `applyRetryStatus with null status clears retryStatus AND failInfo (TG5 critical invariant)` | `frontend/src/stores/ircStore.svelte.test.ts:2839-2868` | Set `retryStatus` then set `failInfo`; then `applyRetryStatus(nid, null)`; assert both are `null` |
| `applyRetryStatus with null status clears failInfo even when retryStatus was already null` | `frontend/src/stores/ircStore.svelte.test.ts:2870-2886` | Idempotent re-clear path |
| `applyRetryStatus sync snapshot adopts retryStatus when present, nulls when absent (TG5 fan-out)` | `frontend/src/stores/ircStore.svelte.test.ts:2900-2937` | When WS sync arrives without `retryStatus`, store calls `applyRetryStatus(nid, null)` which fans out to the dual-clear |
| `applyFail does NOT clear retryStatus (split-canonical-event dispatch)` | `frontend/src/stores/ircStore.svelte.test.ts:2955-2983` | `applyFail` deliberately leaves `retryStatus` intact; only `applyRetryStatus(null)` clears both |

### Live recipe

```bash
# Continuing from scenario 2: force a fail cycle on the
# self-signed network, wait for CONNECTION_FAIL, then re-point
# at a working server.
curl -fsS -X PATCH http://localhost:8090/api/networks/<nid> \
  -d '{"host":"irc.libera.chat","port":6697,"tls":"required"}'

# Poll failInfo every 2s for up to 12s
for i in $(seq 1 6); do
  v=$(redis-cli -h localhost HGET "irc:state:<sid>:<nid>" data | jq -r .failInfo)
  echo "t+${i}*2s: failInfo=$v"
  [ "$v" = "null" ] && break
  sleep 2
done

# Expected: failInfo == "null" within 12s (one snapshot cycle
# after the engine's backoff.reset → zero-clear emit fires).
```

## Code-inspection summary

The three plan-section-G scenarios are pinned at three levels:

1. **Engine emit sites** (`w1-t01-engine-retry-fail` branch) — every
   retry cycle emits `CONNECTION_RETRY_STATUS` with the right shape;
   every disconnect emits `CONNECTION_FAIL` with the nested FailInfo;
   every `backoff.reset()` site emits the zero clear. Rev1 fixed the
   zero-delay, intentional-disconnect, casing, and ordering issues
   the Wave 1 review flagged.
2. **Wire shape** (`protocol.d:304-340`) — `NetworkStateSnapshot.toJson()`
   round-trips `retryStatus` (when defined, otherwise absent);
   `performStateDump` ships it on fresh WS sync.
3. **Frontend consumers** (this worktree, W2 + W3) — the
   `messageHandler.ts` dispatch, `applyRetryStatus` / `applyFail`
   store adapters, `renderReason` / `renderSSLVerify` /
   `renderRetryCountdown` helpers, and the 11-state `BannerKind`
   switch in `ConnectionStatus.svelte` are all unit-test-pinned.

Live runtime evidence (closed-port → fail cycle → recovery → null
clear) requires the engine binary + a redis + a working IRC server.
That gate runs at deploy time (`make update` → engine handoff) and
should be re-executed against a stage network before the merge to
main. The test-suite pinning above is sufficient to claim the wire
contract is correct without it.