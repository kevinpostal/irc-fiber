# gem-critic — 20260716-irccloud-parity

## Blockers

### B1. Engine never emits `connectionState: 'waiting_to_retry'` — countdown branch is dead code
- **Severity:** BLOCKER
- **Evidence:** Plan W3-T01:851,893 declares a `waiting_to_retry` banner branch with 1s countdown. Plan W1-T01:152-185 adds `attemptCount`/`nextRetryAtMs` fields but does not touch `ConnectionState`. `source/ircfiber/irc/connection.d:1575` sets `state = ConnectionState.connecting` for the entire backoff loop (before AND during the sleep at line 1595) — grep confirms zero `waiting_to_retry` writes anywhere in `source/`. The `ConnectionState` enum already has the variant (`types.ts:19`) but nothing emits it. Effect: `isReconnecting = isConnecting && disconnectReason.length > 0` (`ConnectionStatus.svelte:19`) keeps showing the legacy "Reconnecting to {host}…" text during the backoff window, and the new `waiting_to_retry` countdown branch never triggers.
- **Fix:** Add `state = ConnectionState.waiting_to_retry;` immediately before the deadline/sleep at `connection.d:1595`, and `state = ConnectionState.connecting;` (already there) before `attemptConnection()` runs. Emit a CONNECTION_RETRY_STATUS event at the `waiting_to_retry` assignment and another (with `attemptCount: 0`, `nextRetryAtMs: 0`) at the `backoff.reset()` sites (line 1044, 1193, 1831) so the frontend can null `retryStatus` + `failInfo` on successful connect.

### B2. FailInfo JSON shape mismatch between engine (flat) and frontend (nested)
- **Severity:** BLOCKER
- **Evidence:** Plan W1-T01:202-211 defines `FailInfo { string type; string reason; string killedReason; string sslVerifyErrorType; string sslVerifyErrorError; }` (4 flat fields). Plan contracts line 125 wire format: `fi:{t,r,sve,kr}` (4 keys, also flat). Plan W2-T02:455-457 frontend interface declares `sslVerifyError?: { type: string; error: string }` (nested object). Plan W3-T02:1049 test data passes `sslVerifyError: {type:'bad_cert', error:'cert_expired'}` (nested). Conversion is unspec'd.
- **Fix:** Pick one shape. Recommendation: emit nested `{sslVerifyError: {type, error}}` from the engine to match the TS interface, simplify the D struct to `FailInfo { string type; string reason; string killedReason; string[][string] sslVerifyError; }` (Json for the nested object), and document the JSON shape in `contracts:` rather than hand-coding flat `sve/kr` keys.

### B3. `backoff.reset()` does not emit CONNECTION_RETRY_STATUS — failInfo persists across successful reconnect
- **Severity:** BLOCKER (logic gap → stale UI)
- **Evidence:** Plan W2-T02:481-483 specifies `applyRetryStatus(networkId, null)` clears `net.failInfo`. But `applyRetryStatus` is only called when the engine emits `CONNECTION_RETRY_STATUS` with a payload. Plan W1-T01:173-175 says reset sites (line 1044, 1193) "Reset both fields" but does NOT specify emitting CONNECTION_RETRY_STATUS at those sites. Result: `retryStatus`/`failInfo` never null out on successful connect → "Disconnected: Connection refused" banner stays on screen after the user reconnects successfully.
- **Fix:** Add explicit emission in W1-T01 description: at each `backoff.reset()` site, call `eventChannel.put(IRCRawEvent.makeConnectionRetryStatus(network, nid, 0, 0, 0))` so `applyRetryStatus(null)` fires and clears `failInfo`. Add a test asserting failInfo is null after a successful connect following a fail cycle.

### B4. W4-T01 Svelte 5 `$bindable` on `<details open={...}>` is not how `<details>` works
- **Severity:** BLOCKER (correctness — UI breaks)
- **Evidence:** Plan W4-T01:1241-1254 writes `<details ... open={!serverlogCollapseEvents} ontoggle={(e) => ...}>` and says "use Svelte 5 `$bindable` for the open attribute". `<details>`'s `open` attribute is a native DOM property; Svelte 5 `$bindable` is for component prop two-way binding, not for forcing reactivity onto a native attribute that the browser toggles independently. Browser toggles `open` natively on click, fires `ontoggle`, the handler writes the inverse to the store, the store change re-renders `open={!pref}` — but on the next paint cycle the browser already wrote its own value, and Svelte's reactive update may fight the browser's. The plan's $derived is local-component; if `getServerlogCollapseEvents()` returns a plain value (not a $state read inside a $derived/effect context), the change won't trigger a re-evaluation. Plan W2-T03:587 stores `_serverlogCollapseEvents` as `$state<boolean>` and the getter is `return _serverlogCollapseEvents` — the read inside `$derived(getServerlogCollapseEvents())` IS tracked, but the plan needs to confirm this.
- **Fix:** Either (a) bind via `bind:open` with a local `let open = $state(!getServerlogCollapseEvents())` and an effect that mirrors store changes, OR (b) drop the Svelte 5 magic and use a plain `open={!serverlogCollapseEvents}` with the `ontoggle` handler updating the store, accepting that the prop is write-once per render. Add a test that toggles the pref via `setServerlogCollapseEvents` from another component and asserts the `<details>` re-renders within 50ms.

## Risks (top 5)

### R1. CONNECTION_FAIL text-parsing heuristics are unspecified — FailInfo.type field is hand-waved
- **Likelihood:** high. **Impact:** high. **Mitigation in plan:** none — plan W1-T01:178-182 lists reason keywords but no mapping table. **Additional:** require a `parseReasonToFailInfo(reason, lastErrorText)` helper in `connection.d` with an explicit `static immutable FailInfo[string] reasonMap` keyed on substrings of `reason` (`"nxdomain"` → `connecting_failed`/`nxdomain`, `"econnrefused"` → `connecting_failed`/`econnrefused`, `"Connection closed unexpectedly"` → `socket_closed`/`closed`, `"Failed to connect:..."` → `connecting_failed`/*, `"Overridden"` / `ERR_NICKNAMEINUSE` → `killed`/`killed_reason`). Add a unit test for each mapping.

### R2. Dual-emit (`disconnectReason` legacy string + `failInfo` structured) creates divergent rendering paths
- **Likelihood:** medium. **Impact:** medium. **Mitigation in plan:** quality_warnings line 46-47 notes this. **Additional:** the existing `ircStore.svelte.ts:2069-2073` `handleConnect` writes `disconnectReason = text` on DISCONNECT. The new `applyFail` writes `net.failInfo`. The banner's render branch must deterministically pick one (failInfo first, fallback to disconnectReason — already specified in W3-T01). Add a test that asserts both fields are populated from a real disconnect event and that the banner shows failInfo-derived text.

### R3. Engine dub test is broken on main — engine changes have zero unit-test gate
- **Likelihood:** high (assumed). **Impact:** high. **Mitigation in plan:** "Smoke against closed-port" only. **Additional:** `connection-registration-test` exercises registration timeout but NOT the reconnect loop. Pointing at `127.0.0.1:1` fails at TCP `econnrefused` before registration starts, so CONNECTION_RETRY_STATUS emission is never tested. Add a third smoke scenario: point at `127.0.0.1:1` and observe retryStatus after `backoff.nextDelay()` is called at least twice (need a 10s+ sleep in the test); assert `attemptCount >= 2` and `nextRetryAtMs` is within `delayMs + 1s` of `now`. The current smoke acceptance criterion only checks "at least one cycle" — too weak.

### R4. Two collapse concepts coexist (`serverlogCollapsedMap` per-attempt + new global `serverlogCollapseEvents`)
- **Likelihood:** certain. **Impact:** low/UX. **Mitigation in plan:** "independent" (W2-T03:646). **Additional:** users have to discover both. The plan hides this by adding a context-menu "Show connection events" toggle (mentioned in TLDR but no task owns it). Without the menu item, the only way to toggle the global pref is clicking the `<details>` summary — non-obvious. Add a task W4-T03 for the context-menu item, or remove the per-attempt pref in this plan.

### R5. `--fiber-amber-soft` referenced in CSS but not listed in known-existing tokens
- **Likelihood:** medium (unverified). **Impact:** medium (visual — fail banner has no bg). **Mitigation in plan:** assumption line 72 lists `--fiber-amber` as existing but NOT `--fiber-amber-soft`. **Additional:** verify the homepage CSS at `deploy/...` or `frontend/src/app.css` for `--fiber-amber-soft`. If absent, either define it (one-time token: `rgba(255, 179, 0, 0.08)`) or fall back to `rgba(255, 179, 0, 0.08)` literal in `.connectionStatus--fail`.

## Over-engineering / scope creep

### OE1. `renderPostError` (25 entries) and `renderRestricted`/`renderRestrictedShort` (4 entries) ported with no consumer
- Plan W2-T01:339-348 ports the entire `POST_ERRORS` table (paste_too_large, file_too_large, image_too_large, blocked_command, etc.) and `RESTRICTED_REASONS` table. Plan explicitly says fiber has no tier system (line 63, line 345). No task in W3 or W4 calls `renderRestricted` or `renderPostError`. ~30 lines of pure-helper table shipped with no call site. Trim W2-T01 to `renderReason` + `renderSSLVerify` + `suspiciousConnection`; add the others later when the consumer exists.

### OE2. Five of eleven banner states are unreachable from fiber's ConnectionState enum
- Plan W3-T01:842-853 table lists `queued`, `connected_joining`, `ip_retry`, `quitting`, `connected_ready` with `focusOnMakeBuffer`. Fiber's `ConnectionState` (`types.ts:17-23`) has `connected_joining` and `queued` as variants, but the engine at `connection.d:557,685` only writes `connecting`, `connected`, `disconnected`. `ip_retry`, `quitting`, `connected_ready`+`focusOnMakeBuffer` have no producers in the engine, no fields on `Network`, and no plan task to add them. The banner ships 5 dead branches. Either gate these as "TODO: emit from engine" or remove from the plan.

### OE3. `failInfo.sslVerifyErrorType` + `sslVerifyErrorError` (D) → `sslVerifyError: {type, error}` (TS) conversion is invisible work
- Per B2. The dual-shape adds 4 lines of conversion in `messageHandler.ts` that aren't called out, aren't tested, and aren't in the contract. Either keep flat in both layers (simpler) or nest in both — not mix.

### OE4. W2-T04 ships the `<details>` wrap; W4-T01 ships it AGAIN
- W2-T04:656-774 includes 6 acceptance criteria + 10 test cases for the connection-events wrap. W4-T01:1223-1335 ships the "final" implementation with another test case (count badge). Net effect: the wrap is implemented twice (once in Wave 2's draft, once in Wave 4's ship). Either merge W2-T04 + W4-T01 into one Wave-4 task, or move the design into a planning-only task with no code change in W2.

### OE5. Wave 3 + Wave 4 each have their own gem-reviewer gate task (W3-T03, W4-T02) + Wave 5 has a full review (W5-T03)
- 3 review tasks for 8 implementer tasks. Reviewer overhead exceeds implementer overhead. Drop W3-T03 OR W4-T02 (keep one wave gate + the final full review).

## Test gaps

### TG1. No test for failInfo→renderReason interaction (e.g. `failInfo.reason='econnrefused'` → `renderReason('econnrefused')` → 'Connection refused')
- Plan W3-T02 case E asserts the final string "Failed to connect - Connection refused" but doesn't decouple the renderReason call from the banner template. If `renderReasons.ts` returns the wrong string, the banner test fails without indicating which layer broke. Add a `renderReasons.test.ts` case asserting `renderReason('econnrefused') === 'Connection refused'` (W2-T01 claims exhaustive coverage — verify).

### TG2. No test for the legacy `disconnectReason` fallback path when `failInfo` is absent
- Plan W3-T01:1078-1081 derives banner text from `failInfo` first then `disconnectReason`. No test renders a network with `disconnectReason='Connection reset'` and `failInfo=undefined` and asserts the banner shows "Disconnected: Connection reset" (fallback). The 5 existing tests cover this case for the legacy banner but not after the rewrite.

### TG3. No test for ISUPPORT panel render inside the new `<details>` (after W4-T01's $bindable change)
- Plan W2-T04:774 asserts this. Plan W4-T01 only adds the count-badge test. If W4-T01's binding changes break the assertion, no test catches it. Add to W4-T01.

### TG4. No test for the `--fiber-amber-soft` token resolves (see R5)
- The hairline-bar visual acceptance (W3-T01:1006) checks `border-top-width: 1px` and `border-bottom-width: 1px` but not the fail-state background color. If `--fiber-amber-soft` doesn't resolve, the test passes silently.

### TG5. No test for `applyRetryStatus` clearing `failInfo` on null (interplay)
- Plan W2-T02:481-483 wires `if (!status) net.failInfo = null` but the acceptance criteria + tests at W2-T02:553-555 + W3-T02 don't exercise it. Add: `applyRetryStatus('net1', {attemptCount:2, nextRetryAtMs: ..., delayMs: ...})` then `applyRetryStatus('net1', null)` → assert `net.failInfo === null`. Critical for B3.

### TG6. `connection-registration-test` smoke doesn't exercise the reconnect loop (see R3)
- The smoke at W1-T01:244-252 points at `127.0.0.1:1` which fails at TCP `econnrefused` — registration timeout never starts, `CONNECTION_RETRY_STATUS` emission is unverified. Add a sleep-and-assert retryStatus update.