# prefVersion — engine-vs-client merge resolution

> Wave 1 / R#11 / W1-T02
> Status: implemented

## What it is

`prefVersion` is a monotonically increasing `long` counter stored **inline**
in the per-user preferences JSON blob (`prefs:<userId>` in Redis). It is
bumped by exactly one on every successful `prefsRepo.save()` call. The
value is included in:

- the `stat_user` WebSocket boot message (so the frontend can decide
  whether to trust the payload on first paint)
- every `pref_update` broadcast published via `RedisKeys.events(userId)`
  (so other tabs/devices see the canonical counter in real time)
- the `GET /api/me` REST response (for parity with boot)

```json
{
  "pinnedChannels": [],
  "archivedChannels": [],
  "pinnedChannels": [],
  "bufferPrefs": {},
  "prefVersion": 42,
  ...
}
```

## When it resolves

`prefVersion` resolves the **engine-vs-client** conflict on the boot path.
The scenario:

1. User collapses a server-log card in tab A. `preferences.svelte.ts`
   writes the collapse to `localStorage` and POSTs to
   `/api/me/serverlog-collapsed`. The engine calls `prefsRepo.save()`
   which bumps `prefVersion` to N+1.
2. The gateway caches the `stat_user` payload for tab B, which is
   already mid-handshake. Tab B receives a stale `stat_user` whose
   `prefVersion` is the pre-N+1 value.
3. Without `prefVersion`, tab B would re-apply the stale payload and
   snap the card back to expanded (visible flicker) on first paint.
4. With `prefVersion`, `mergePreferences()` reads
   `serverPrefVersion=N+1` (or whatever the cached value is) and
   compares it against the local floor. If the local floor is strictly
   greater, the merge is skipped — the stale payload cannot win.

This is the **last-write-wins** strategy. It does not need wall-clock
synchronization between the server and the client; monotonicity is all
that's required, and the engine is the single source of truth for the
counter.

## When it does NOT resolve

`prefVersion` does **not** resolve the **tab-vs-tab** conflict on the
same device. That path uses a different mechanism:

- When tab A flips a collapse, it writes to `localStorage` and emits a
  `storage` event (which Svelte listens for in
  `preferences.svelte.ts`). Tab B picks up the change via the
  `storage` event without ever round-tripping through the engine.
- The engine is then notified via the REST endpoint so the persisted
  blob catches up. The next `prefsRepo.save()` bumps `prefVersion`,
  which feeds back into the engine-vs-client gate above.

So tab-vs-tab is handled by the browser's `localStorage` storage
event, and engine-vs-client is handled by `prefVersion`. The two
mechanisms are complementary: localStorage events are fast and
don't touch the network; `prefVersion` is the safety net for when
the engine's authoritative state diverges from what the client
thinks it knows.

## Atomicity guarantee

`prefsRepo.save()` runs a single Redis Lua script via `EVAL`:

```lua
local current = redis.call('GET', KEYS[1])
local newPrefVersion = 1
if current then
    local ok, parsed = pcall(cjson.decode, current)
    if ok and type(parsed) == 'table' and parsed.prefVersion then
        newPrefVersion = tonumber(parsed.prefVersion) + 1
    end
end
local ok2, newDoc = pcall(cjson.decode, ARGV[1])
if not ok2 or type(newDoc) ~= 'table' then
    return redis.error_reply('preferences.d: invalid JSON in ARGV[1]')
end
newDoc.prefVersion = newPrefVersion
redis.call('SET', KEYS[1], cjson.encode(newDoc))
return newPrefVersion
```

The script does **GET → parse → increment → set** in one atomic step.
Redis executes Lua scripts on its single-threaded command loop, so
from every other client's perspective the read-modify-write is
uninterruptible. Two concurrent `save()` calls therefore cannot
both observe the same `prefVersion` and overwrite each other's
increment — exactly the bug class this counter exists to prevent.

### Why Lua and not MULTI/EXEC?

Vibe-d's `RedisDatabase` (vibe-d 0.10.3) does not expose a typed
`MULTI`/`EXEC` builder (the API carries a `TODO: Transactions`
comment in `vibe/db/redis/redis.d`). Lua via `EVAL` is Redis's
canonical atomic primitive and is fully supported by the
existing `eval!long(...)` wrapper on `RedisDatabase`.

The fallback path (a plain `SET` without an increment) is
deliberately retained for the case where `EVAL` itself fails
(e.g. transient Redis failure). The fallback writes the caller-
supplied `prefVersion` (which is `0` — the in-memory value
before the Lua ran), so the counter will be wrong on that save,
but the next successful save will repair it. We do not silently
swallow the failure: the caller sees `prefVersion=0` returned
and can decide how to surface that.

### Concurrency test

A unittest in `source/ircfiber/db/preferences.d` runs N=50 parallel
saves against a local Redis, each appending a unique pinned channel,
and asserts:

- the final `prefVersion` equals N (strictly monotonic, no skipped
  values, no duplicates)
- all N pinned channels are present in the final blob

The test is gated on a local Redis being reachable; it logs and
returns if Redis is unavailable so CI without Redis can still
pass.

## What prefVersion does NOT solve

| Conflict class               | Mechanism                       | Notes                                |
|------------------------------|---------------------------------|--------------------------------------|
| Tab-vs-tab (same browser)    | `localStorage` storage event    | Free, immediate, no network          |
| Engine-vs-client (boot)      | `prefVersion` last-write-wins   | Engine is authoritative              |
| Engine-vs-engine (handoff)   | Single-engine gate + atomic SET | Only one engine owns a network       |
| Server-side admin override   | Out of scope for W1-T02         | Would need a separate `forceVersion` |

The first three rows are sufficient for the Wave 1 parity milestone
with IRCCloud. The fourth row (admin forcing a new server-side
schema) is a future consideration: an admin that wants to
invalidate every client's local cache could write a sentinel
`prefVersion = -1` and have the frontend treat negative values as
"discard local state" — but this is not implemented yet and is
explicitly out of scope for this task.

## Related files

- `source/ircfiber/db/preferences.d` — D struct + `PreferencesRepository`
- `source/ircfiber/api/rest.d` — `getMe()`, `broadcastPrefUpdate()`
- `source/ircfiber/api/websocket.d` — `sendStatUser()` (1-line addition)
- `frontend/src/App.svelte` — `handleStatUser`, `mergePreferences`, `handlePrefUpdate`
- `frontend/src/App.test.ts` — W1-T02 prefVersion gate tests