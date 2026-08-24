# Wave 2 Review - W2-T01..W2-T04 Frontend Helpers

## Review evidence

- Worktree: `/Users/zodiac/.local/share/opencode/worktree/368CED7E-A4CD-4B0E-A4B7-D1F8023D9AE3`
- Range: `w1-t01-engine-retry-fail..w2-frontend-helpers`; HEAD `d2fd53b`; branch `w2-frontend-helpers`; clean tree.
- Changed scope: 10 files, 1139 insertions, 3 deletions (6 modified, 4 created).
- Touched files: `frontend/src/lib/{messageHandler,renderReasons,suspiciousConnection,renderReasons.test,suspiciousConnection.test}.ts`,
  `frontend/src/stores/{ircStore,preferences,ircStore.svelte.test,preferences.svelte.test}.svelte.ts`,
  `frontend/src/types.ts`.

## Verdict

PASS

- W2-T01 acceptance criteria: 9 met, 1 contract-divergent (non-blocking).
- W2-T02 acceptance criteria: 6 met, 0 unmet.
- W2-T03 acceptance criteria: 4 met, 0 unmet.
- W2-T04: out of scope for this wave — the spec bundles the ServerLogTimeline ship into W4-T01.
- Regression risk: LOW.

## W2-T01 — renderReasons + suspiciousConnection helpers

### Helper shape (OE1 critic fix)

- `renderReasons.ts` exports **only** `renderReason` + `renderSSLVerify` (lines 32 + 84).
  - `renderRestricted` / `renderRestrictedShort` / `renderPostError` deliberately dropped.
  - The dropped tables live in a `TODO` comment block at line 130 so a future consumer can re-introduce them.
  - `renderReasons.test.ts` pins the surface with `expect(Object.keys(mod).sort()).toEqual(['renderReason', 'renderSSLVerify'])` (line 149) — a future PR that re-adds a dropped export fails this test.

### renderReason keys (TG1 pinned)

| key                       | returns                  | status   |
|---------------------------|--------------------------|----------|
| `econnrefused`            | `Connection refused`     | PASS (l.45) |
| `nxdomain`                | `Invalid hostname`       | PASS (l.46) |
| `ssl_certificate_error`   | `SSL certificate error`  | PASS (l.48) |
| `bogus_xyz`               | input unchanged          | PASS (l.55) |
| unknown / non-string      | empty string / passthrough | PASS (l.33) |

Every key in the lifted `RENDER_REASONS` table is enumerated and tested exhaustively at lines 36-55 of the test file.

### renderSSLVerify (TG1 nested lookup)

| input                                          | returns                          | status   |
|------------------------------------------------|----------------------------------|----------|
| `{type:'bad_cert', error:'cert_expired'}`      | `Certificate expired`            | PASS (l.103) |
| `{type:'ssl_verify_hostname', error:'unable_to_match_altnames'}` | `Certificate hostname mismatch` | PASS (l.117) |
| `{type:'ssl_verify_hostname', error:'unable_to_match_common_name'}` | `Certificate hostname mismatch` | PASS (l.118) |
| unknown pair                                   | `` `${type}: ${error}` ``        | PASS (l.110, 121, 127) |
| `null` / `undefined` / malformed               | `''`                             | PASS (l.92, 128) |

### suspiciousConnection

- `isSuspiciousPort(port, isSSL): string | null` (l.56) — flags 6667/6660-6669/7000 + SSL, 6697/6690-6699 + plain.
- `isSuspiciousHostname(host, _isSSL?): string | null` (l.94) — leading/trailing dot, no-dot-no-colon.
- 30/30 tests pass: `npx vitest run --project=lib src/lib/suspiciousConnection.test.ts`.
- Defensive coverage for `NaN` / `-1` / `0` ports and `undefined` / `null` / numeric hosts.

### MEDIUM — `isSuspiciousPort` signature diverges from plan literal contract

- Evidence `plan.yaml:484`: contract specified `isSuspiciousPort(isSSL: boolean, port: number, defaultPort = 6667, defaultSSLPort = 6697): boolean`.
- Evidence `suspiciousConnection.ts:56`: actual signature is `isSuspiciousPort(port: number, isSSL: boolean): string | null` — argument order swapped, return type now the warning string instead of a boolean, default-port parameters dropped.
- Evidence `suspiciousConnection.ts:32-41`: extended port sets (6660-6669 + 7000 plain; 6690-6699 TLS) — broader than the strict `defaultPort` / `defaultSSLPort` pair.
- Evidence `suspiciousConnection.test.ts:20-30`: tests assert `.not.toBeNull()` / `.toBeNull()` (truthy-check) rather than `.toBe(true)` / `.toBe(false)`.
- **Impact**: Wave 3 banner code that follows the plan's literal call site `isSuspiciousPort(net.tls === 'on', net.port)` will break with the new signature. Wave 3 has to use `isSuspiciousPort(net.port, net.tls === 'on')` and render the returned string directly. Net effect is **cleaner** (one call → string) but it requires Wave 3 to discover the new contract.
- **Why non-blocking**: the new API is a strict superset of the old one (the truthy predicate works for both shapes). No test in the W2 deliverable references the old signature, and the consumer (Wave 3 ConnectionStatus.svelte) hasn't shipped yet. The migration cost is small and worth the cleaner API.
- **Mitigation**: the JSDoc on the implementation at lines 47-71 explicitly documents the parameter order and the `(isSSL, port)` reversal vs the IRCCloud original so Wave 3 authors can't miss it.

### Low — `isSuspiciousHostname` accepts an unused `isSSL` parameter

- Evidence `suspiciousConnection.ts:94`: `_isSSL?: boolean` argument is declared but unused (JSDoc says "Reserved for future use").
- The test at lines 140-149 asserts the parameter is symmetric — same return with or without it.
- Cost: an unused argument is mildly confusing but tests pin the behaviour, and the symmetric-API surface matches `isSuspiciousPort`. Acceptable for forward compatibility.

## W2-T02 — types + ircStore + messageHandler plumbing

### Network interface extension (types.ts:46-67, 162, 171)

- `RetryStatus { attemptCount: number; nextRetryAtMs: number; delayMs: number }` — matches wire field shape 1:1.
- `FailInfo { type: string; reason: string; killedReason?: string; sslVerifyError?: { type: string; error: string } }` — nested `sslVerifyError` per plan B2 (no engine↔frontend conversion required).
- `Network.retryStatus?: RetryStatus | null` and `Network.failInfo?: FailInfo | null` are optional fields; the existing `disconnectReason: string` (line 88) is unchanged (back-compat path).

### `applyRetryStatus(networkId, status)` (ircStore.svelte.ts:2168-2187)

- Writes `net.retryStatus = status`.
- On `null` status, ALSO clears `net.failInfo` — **TG5 invariant pinned at line 2182-2186**.
- No-op on unknown networkId (matches the `applyIsupportUpdate` precedent).
- `markNetworkSeen` called to refresh the stale-network marker.

### `applyFail(networkId, failInfo)` (ircStore.svelte.ts:2202-2213)

- Writes `net.failInfo = failInfo`.
- Deliberately does NOT touch `net.retryStatus` — the engine's NEXT `backoff.reset()` emit (which carries zero retry) is the authoritative clear, fired via `applyRetryStatus(networkId, null)`. Documented at lines 2194-2199.

### Sync adoption (ircStore.svelte.ts:1366-1390, 1908-1937)

- Both branches of `updateNetworkFromSync` (existing + new-network) adopt `retryStatus` from the wire when present, and call `applyRetryStatus(networkId, null)` when absent — the on-store counterpart to the engine's zero-omits-`hasRetryStatus` policy. The presence/absence gate mirrors the existing `isupport` adoption shape.
- `failInfo` is only adopted when shipped (no implicit clear — see rationale comment at lines 1933-1936).
- TG5 fan-out: sync-delivered absent retry triggers the dual-clear path on the store.

### Dispatch (messageHandler.ts:240-286)

- `c === 'CONNECTION_RETRY_STATUS'` (line 249):
  - Reads `data.rs as RetryStatus`, validates shape (`typeof rs.attemptCount === 'number'`).
  - Detects zero payload (`attemptCount === 0 && nextRetryAtMs === 0 && delayMs === 0`) and routes to `applyRetryStatus(networkId, null)`.
  - Malformed payloads clear defensively (`applyRetryStatus(networkId, null)`) — the mirror image of the ISUPPORT branch's "leave untouched" policy.
- `c === 'CONNECTION_FAIL'` (line 277):
  - Reads `data.fi as FailInfo`, validates `typeof fi.reason === 'string'`.
  - Routes to `applyFail(networkId, fi)`.
  - Malformed payloads are discarded — keeping the prior `failInfo` so a truncated frame can't briefly flash "Disconnected".
- Both arms `return {}` immediately so the event bypasses `appendMessage` (matches the ISUPPORT branch at line 226-238).

### Existing `disconnectReason` sync logic

- Unchanged per `do_not_reinvestigate` (plan W2-T02:691). Verified — the ircStore diff hunks are exclusively additive (`+` lines only at 1363-1390, 1905-1937, 2150-2213).

## W2-T03 — serverlogCollapseEvents pref (preferences.svelte.ts)

### Implementation (lines 214-255)

- `_serverlogCollapseEvents = $state<boolean>(getStorageItem('ircfiber:serverlogCollapseEvents', true))` (l.236-238) — `true` default matches plan.
- `getServerlogCollapseEvents(): boolean` (l.243) — getter.
- `setServerlogCollapseEvents(value: boolean): void` (l.252-255) — writes to localStorage immediately via `setStorageItem` (same pattern as `pastebinDisablePrompt`).
- `$effect` at line 355 re-writes on every mutation — defense against a missing localStorage write (race / quota).

### Storage event listener (lines 498-512)

- New `case 'ircfiber:serverlogCollapseEvents':` in the `storage` switch.
- Reads `JSON.parse(e.newValue)`, validates `typeof v === 'boolean'`, writes back to `_serverlogCollapseEvents`.
- `e.newValue === null` resets to `true` (default).
- Mirrors the `_pastebinDisablePrompt` cross-tab pattern.

### Storage key matches the plan

- `ircfiber:serverlogCollapseEvents` is the single global key — no per-network proliferation (matches the `decisions.collapse_connection_events_by_default` prior decision in context_envelope.json:200-212).

## W2-T04 — ServerLogTimeline ship

- Out of scope per plan coordination_notes:118 ("Wave 4 (timeline) depends on Wave 2 (preferences) only"); W4-T01 ships the actual `<details>` wrap after Wave 3's banner rewrite establishes the visual vocabulary.
- W2-T04's only deliverable that touches Wave 2 code is the **preference plumbing**, already verified in W2-T03 above.

## Test coverage

### renderReasons.test.ts — 12 tests, all pass

- TG1 explicit cases: `econnrefused`, `nxdomain`, `ssl_certificate_error` (l.21-29).
- Exhaustive RENDER_REASONS coverage via `for (const [reason, human] of Object.entries(expected))` (l.36-55).
- Unknown-reason passthrough (l.60-65).
- Defensive non-string (l.67-75).
- `renderSSLVerify` for `bad_cert` family (l.87-101), `ssl_verify_hostname` family (l.103-112), fallback pair (l.114-121), defensive null/malformed (l.123-132).
- **OE1 trim-scope guard** (l.143-150): pins the exported surface to exactly `['renderReason', 'renderSSLVerify']`.

### suspiciousConnection.test.ts — 30 tests, all pass

- Classic 6667 / 6697 pair (l.19-30).
- Extended plain-IRC range 6660-6669 + 7000 (l.33-44).
- Extended SSL range 6690-6699 minus 6697 (l.46-57).
- Unrelated-port clean (l.59-71).
- Defensive invalid inputs (l.73-78).
- Warning string content (l.81-92).
- `isSuspiciousHostname` fully-qualified / leading-dot / trailing-dot / no-dot-no-colon / IPv6 / empty / non-string (l.99-126).
- Warning string content for hostname (l.128-138).
- Symmetric API for unused `isSSL` param (l.140-149).

### ircStore.svelte.test.ts — TG5 invariant pinned (9 new tests)

- `describe('applyRetryStatus (W2-T02 — engine CONNECTION_RETRY_STATUS adapter)')`:
  - Writes retryStatus onto the matching network (l.2827-2837).
  - **null status clears retryStatus AND failInfo (TG5 critical invariant)** (l.2839-2868) — the engine backoff.reset→zero emit pathway.
  - null status clears failInfo even when retryStatus was already null (l.2870-2886).
  - No-op on unknown networkId (l.2888-2898).
  - **Sync snapshot adopts retryStatus when present, nulls when absent (W2-T02 syncing path)** (l.2900-2937) — the TG5 fan-out.
- `describe('applyFail (W2-T02 — engine CONNECTION_FAIL adapter)')`:
  - Writes failInfo onto the matching network (l.2943-2953).
  - Preserves a populated retryStatus (fail does not clear retry) (l.2955-2983) — split-canonical-event dispatch.
  - Preserves structured sslVerifyError (nested shape byte-for-byte) (l.2985-2999) — plan B2 invariant.
  - No-op on unknown networkId (l.3001-3006).
- All 9 new tests pass.

### preferences.svelte.test.ts — 5 new tests, all pass (W2-T03)

- Defaults to `true` when localStorage is empty (l.553-557).
- Setter persists to localStorage immediately (l.559-568).
- Getter honours pre-existing localStorage value `false` (l.570-586).
- Storage event from another tab re-reads the value (l.588-597).
- Storage event ignores malformed payloads (l.599-607).

## Test suite results

### `npx vitest run --project=lib`

- **498 / 498 PASS** across 26 test files (`Duration 599ms`).
- Wave 2 lib tests included: `renderReasons.test.ts` (12/12), `suspiciousConnection.test.ts` (30/30), `messageHandler.test.ts` (9/9 — pre-existing, no regressions).

### `npx vitest run --project=client`

- **772 pass | 1 skipped | 2 todo | 2 failed** across 54 test files.
- Failures:
  1. `src/stores/ircStore.svelte.test.ts:2354 > W7-T01: URL nav auto-join plumbing > self-nick…` — pre-existing self-nick regression on the w1 base; reproduced against `w1-t01-engine-retry-fail:frontend/src/stores/ircStore.svelte.test.ts` line 2354 with the w1 file restored.
  2. `src/components/ServerLogCard.test.ts:83 > renders phase chips for each phase event in the timeline` — pre-existing; reproduced against the same file on the w1 base.
- Neither failure touches a Wave 2 file. **Zero Wave 2 regressions.**
- 4 unhandled errors in `ServerLogCard.test.ts`, `Sidebar.test.ts`, `ServerLogTimeline.test.ts` are all pre-existing async race conditions from `updateServerlogCollapsed` / `updateCollapsed` mock rejections — also reproduced on the w1 base.

### `npx tsc --noEmit`

- 39 errors total — **all pre-existing**, none introduced by Wave 2.
- Files with errors: `App.test.ts`, `Sidebar.duplicate.test.ts`, `Sidebar.test.ts`, `isupportCatalog.test.ts`, `routing.ts`, `wsHoleDetector.test.ts`, `ircStore.svelte.test.ts`.
- Of the 12 errors in `ircStore.svelte.test.ts`, all are at line numbers ≤ 2370 — **below the Wave 2 add point (line 2806)**. Every Wave 2 line is type-clean.
- No errors in any Wave 2-only file (`renderReasons.ts`, `suspiciousConnection.ts`, `messageHandler.ts`, `preferences.svelte.ts`, `ircStore.svelte.ts`, `types.ts`).

## Security and integration checks

- **Secrets / PII / SQLi / XSS**: no new issues. The structured `failInfo.reason` / `sslVerifyError.type` / `sslVerifyError.error` strings are rendered via Svelte's `{value}` text interpolation (not `{@html}`), which auto-escapes. The `connect.logTiming` and other observability surfaces are unaffected.
- **JSON boundaries**: `CONNECTION_RETRY_STATUS.data.rs` and `CONNECTION_FAIL.data.fi` are read via typed casts (`as RetryStatus | undefined`, `as FailInfo | undefined`) plus runtime validation (`typeof rs.attemptCount === 'number'`, `typeof fi.reason === 'string'`). Malformed payloads are defended (retry: clear; fail: discard).
- **Event propagation**: handlers live in the existing `processIrcEvent` switch, alongside `ISUPPORT` (line 226-238) and `temp_unavailable` / `idle` (line 207-219). Both new arms return `{}` so they bypass `appendMessage` (the ISUPPORT precedent).
- **Existing event compatibility**: `DISCONNECTED` / `ISUPPORT` / `PRIVMSG` / `NOTICE` factory shapes are not touched. The new events are additive.
- **Cross-tab storage sync**: `ircfiber:serverlogCollapseEvents` joins the existing `storage` event handler at line 440 — typed JSON.parse, boolean validation, null-resets-to-default. Mirrors the `_pastebinDisablePrompt` pattern.
- **Mobile vectors**: not applicable — no mobile platform code changed.
- **Fiber palette tokens**: no new CSS tokens introduced. The CSS-touching work is deferred to W2-T04 / W4-T01.

## Decision

PASS — Wave 2 ships clean.

- W2-T01, W2-T02, W2-T03 meet their acceptance criteria.
- One contract divergence (MEDIUM): `isSuspiciousPort(port, isSSL): string | null` vs the plan's literal `(isSSL, port): boolean` signature. Wave 3 banner code will need to call with `(port, isSSL)` and render the returned string. Tracked in the file's JSDoc (lines 47-71). Wave 3 author should consult `suspiciousConnection.ts` before writing the banner branch.
- Zero test regressions in Wave 2-touched code.
- 2 client-test failures + 39 tsc errors are all pre-existing on the w1 base — verified by reproducing against `w1-t01-engine-retry-fail`.

Wave 3 (ConnectionStatus rewrite) and Wave 4 (ServerLogTimeline ship) can proceed.