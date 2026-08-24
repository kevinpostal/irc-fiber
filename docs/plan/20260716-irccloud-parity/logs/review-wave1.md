# Wave 1 Review - W1-T01 Engine Retry/Fail

## Review evidence

- Worktree: `/Users/zodiac/.local/share/opencode/worktree/1c3c98a196659f0a88c61e14b572de38a84bb5f8/w1-t01-engine-retry-fail`
- Range: `b9b2f4e..369154d`; branch `w1-t01-engine-retry-fail`; worktree clean after tests.
- Changed scope: 6 files, 774 insertions, 7 deletions.
- Supporting scope: `irc/manager.d` channel wiring and `connection_registration_test.d` test coverage.

## Verdict

NEEDS REVISION - BLOCKING

- W1-T01 acceptance criteria: 5 met, 5 unmet.
- Requested verification checklist: 3 met, 3 unmet.
- Regression risk: HIGH.

## Blocking issues

### HIGH - Retry snapshots always report `delayMs = 0`

- Evidence `connection.d:1437-1439`: `return RetryStatus(attemptCount, nextRetryAtMs, 0L);`
- Evidence `state.d:196-197`: the snapshot copies `rs.delayMs` without recomputing it.
- Evidence `protocol.d:304-306`: the zero value is serialized as the public `delayMs`.
- Finding: active retry snapshots cannot satisfy the required `delayMs > 0` closed-port smoke assertion.
- Impact: fresh WS clients receive an invalid retry schedule even though live retry events carry the real delay.

### HIGH - Intentional disconnects are emitted as connection failures

- Evidence `connection.d:822-823`: `stop()` sets `isShutdownRequested = true`.
- Evidence `connection.d:3915-3918`: fail emission checks handoff only, not `isShutdownRequested`.
- Evidence `connection.d:1803-1808`: fail state clears only through `emitZeroRetryStatus()`.
- Finding: user/admin disconnects persist `failInfo` instead of reaching the planned `disconnected` no-fail branch.
- Impact: Wave 3 can render a manual disconnect as failed and choose the wrong action button.

### HIGH - The required nested SSL detail is not reachable from a real TLS failure

- Evidence `connection.d:1951`: `ctx.peerValidationMode = TLSPeerValidationMode.none;` disables peer checks.
- Evidence `connection.d:1970-1977`: TLS exceptions are rethrown without storing `e.msg` in `lastErrorText`.
- Evidence `connection.d:4170`: nested SSL detail is created only when `lastErrorText.length > 0`.
- Finding: a real certificate failure cannot produce the required nested `{type, error}` snapshot payload.
- Security: peer certificate validation is disabled, allowing TLS man-in-the-middle attacks.
- Note: validation was not introduced by `369154d`, but it directly blocks W1 SSL acceptance.

## Other issues

### MEDIUM - Not every `backoff.reset()` site emits the zero clear

- Evidence `connection.d:1657`: the ghost-retry branch calls `backoff.reset()`.
- Evidence `connection.d:1660-1729`: the next emitted retry status is active/non-zero, not a zero clear.
- Finding: the claim that every reset is followed by `emitZeroRetryStatus()` is false; coverage is 3 of 4 sites.

### MEDIUM - Three advertised case-insensitive reason mappings are dead

- Evidence `connection.d:4135-4137`: input is lowercased, but table substrings are not lowercased at compare time.
- Evidence `connection.d:4113-4115`: `Overridden`, `ERR_NICKNAMEINUSE`, and `Connection closed` use capitals.
- Finding: those inputs fall through to `connecting_failed` instead of `killed` or `socket_closed` handling.

### MEDIUM - `FailInfo` and factory signatures do not match the required contract

- Evidence `connection.d:531-548`: the struct uses `string type_`, not the required `string type`.
- Evidence `irc_event.d:311-318`: `makeConnectionFail` accepts four scalar fields plus `Json`.
- Finding: the planned `makeConnectionFail(network, networkId, const ref FailInfo)` contract is absent.
- Positive: `protocol.d:335-342` does serialize `sslVerifyError` as a nested JSON object.

### LOW - Retry event ordering is reversed

- Evidence `connection.d:1727-1731`: `CONNECTION_RETRY_STATUS` is emitted first.
- Evidence `connection.d:1743-1747`: the `queued` server-log event is emitted afterward.
- Finding: the task required the user-visible queued line to land before the structured retry event.

### MEDIUM - Required Wave 1 smoke evidence is absent

- Evidence `docs/plan/20260716-irccloud-parity/logs/` is empty.
- Evidence `369154d` changes only the six engine files; no `engine-smoke.md` or smoke harness was committed.
- Finding: closed-port retry, SSL fail shape, and fail-clear-after-reconnect remain unverified.

## Requested verification checklist

- B1: PASS - `waiting_to_retry` at `connection.d:1717`; active event at `1727-1729`.
- B1: PASS - transition back to `connecting` at `connection.d:1914` before TCP connect.
- B2: FAIL - nested wire object exists, but struct field is `type_` and live SSL detail is unreachable.
- B3: FAIL - zero clear follows 3 reset sites; the fourth reset at `connection.d:1657` has no clear.
- R1: PASS WITH DEFECTS - at least 10 mappings exist; three mixed-case entries never match.
- Factories: FAIL - both exist, but `makeConnectionFail` has the wrong signature.
- Manager broadcast: PASS - `manager.d:83,101` passes `mainEventChannel` directly to each client.

## Acceptance criteria

- AC1 accessors and nullable `getRetryStatus`: FAIL - accessor exists, but is non-null and returns zero delay.
- AC2 engine `waiting_to_retry` enum: PASS.
- AC3 wait-state emit and return to `connecting`: PASS.
- AC4 zero clear at every reset: FAIL - 3 of 4 reset sites.
- AC5 disconnect `FailInfo` plus legacy event: FAIL - manual disconnects fail; SSL detail is unreachable.
- AC6 retryStatus JSON roundtrip: PASS - symmetric fields in `protocol.d:449,503-510`.
- AC7 state snapshot population: FAIL - populated with a permanently zero `delayMs`.
- AC8 fresh WS sync serialization: PASS - `websocket.d:511` ships the object.
- AC9 compile gate: PASS - forced DUB build completed and linked successfully.
- AC10 three-scenario smoke log: FAIL - no smoke artifact exists.

## Security and integration checks

- Secrets/PII/SQLi/XSS: no new issues found in the six changed files.
- JSON boundaries: retry/fail objects are encoded before channel transport and decoded at serialization.
- Event propagation: client instances share `ConnectionManager.mainEventChannel`; no manager change is needed.
- Existing event compatibility: `DISCONNECTED` and `ISUPPORT` factory shapes were not changed.
- Mobile vectors: not applicable; no mobile platform code changed.

## Test results

- PASS: `dub build --force --config=connection-registration-test` linked successfully.
- PASS: `dub run --config=connection-registration-test --skip-registry=all` reported 8/8.
- GAP: the 8 tests cover the legacy admin registration contract, not W1 retry/fail behavior.
- GAP: added `irc_event.d` unittests were not exercised by the required executable test.
- GAP: no closed-port, SSL-failure, or recovery smoke evidence was committed.

## Decision

DO NOT PROCEED TO WAVE 2.

- Persist the actual retry delay and make healthy snapshots nullable/absent as contracted.
- Suppress `CONNECTION_FAIL` for intentional shutdowns and disabled-network removal.
- Make real TLS failures populate nested SSL details and restore peer certificate validation.
- Fix the fourth reset site, lower-case reason-map keys, and align `FailInfo`/factory signatures.
- Commit the three required smoke scenarios with raw Redis or WS evidence.
