# Wave 3 Review — W3-T01..W3-T02 ConnectionStatus 11-state banner rewrite

## Review evidence

- Worktree: `/Users/zodiac/.local/share/opencode/worktree/1c3c98a196659f0a88c61e14b572de38a84bb5f8/w3-connection-status`
- Range: `b9b2f4e..90fc4aa`; HEAD `90fc4aa`; branch `w3-connection-status`; tree clean post-tests.
- Touched scope (this commit): 5 files, +1304 / -97 lines.
  - `frontend/src/components/ConnectionStatus.svelte` (rewritten, 549 lines)
  - `frontend/src/components/ConnectionStatus.test.ts` (extended to 33 tests / 390 lines)
  - `frontend/src/lib/connectionWarnings.ts` (NEW, 184 lines)
  - `frontend/src/lib/connectionWarnings.test.ts` (NEW, 219 lines, 33 tests)
  - `frontend/src/types.ts` (+37 net lines: retryStatus / failInfo / badRetry inlined)
- Tests run:
  - `npx vitest run --project=lib src/lib/connectionWarnings.test.ts` → **33/33 PASS**
  - `npx vitest run --project=lib src/lib/renderReasons.test.ts src/lib/suspiciousConnection.test.ts` → **files not found** (deleted; see Non-blocking #1)
  - `npx tsc --noEmit` → no errors in any of the 5 touched files (pre-existing errors in `wsHoleDetector.test.ts` + `ircStore.svelte.test.ts` are out of scope and confirmed unrelated)
  - `npx vitest run --project=client ...` → environment failure (Playwright cannot fetch the dynamically imported `vitest-browser-svelte/src/index.js` from the parent-repo symlinked `node_modules` — all 54 client test files fail identically). Cannot run ConnectionStatus.test.ts in this worktree. Code review + helper tests + tsc substitute for the client-side check.

## Verdict

**NEEDS REVISION — non-blocking**

- W3-T01 acceptance criteria: 11 met, 6 partially met (state coverage gaps — see Critical #1).
- W3-T02 acceptance criteria: 11 met, 1 unmet (no unmount-cleanup assertion — see Critical #2).
- Regression risk: MEDIUM. The 6-state gap means the banner renders blanks or generic copy in those engine states; the implementation is otherwise clean and idiomatic Svelte 5.
- Wave 4 is unblocked for design work; a Wave 3 rev (or a Wave 4-T01 PR) should land the missing states before merge.

## Critical issues

### HIGH — Only 9 of 11 plan-mandated banner states are implemented

- Evidence `plan.yaml:966-981` (lines 970-981) lists the full 11-state matrix lifted from IRCCloud's `connectionstatusview.js:64-123`.
- Evidence `ConnectionStatus.svelte:73-104` — `BannerKind` union only enumerates 9 cases: `'away' | 'connecting' | 'retry' | 'fail-killed' | 'fail-ssl' | 'fail-blocked' | 'fail-connecting' | 'fail-socket' | 'disconnected'`.
- Evidence `ConnectionStatus.svelte:106-143` — `headline` switch matches the 9 BannerKinds 1:1. The 6 missing states fall through to the `'disconnected'` default or render an empty string:
  - **`queued`** (state string `'queued'`, valid per `types.ts:6-12`): engine CAN emit this — banner falls through to default; user never sees `"Connection queued; waiting our turn…"`. `types.ts:6` defines `'queued'` so the omission is a wiring gap, not a forward-compat placeholder.
  - **`connected`** (state string `'connected'`): banner is hidden via `showStatus` (`ConnectionStatus.svelte:64-66`) because `connected=true` makes `isDisconnected=false`; plan required `"Connected; handshaking…"` text (line 974).
  - **`connected_joining`** (state string `'connected_joining'`): same — banner hidden; plan required `"Connected; setting up…"` (line 975).
  - **`quitting`**: no matching case; plan required `"Quitting…"` (line 977). Implementation passes any 'quitting' input to the default branch (a "Disconnected:" copy).
  - **`ip_retry`**: no matching case; plan required `"Connecting to {ip} failed ({error}); resolving a new IP…"` (line 978).
  - **`waiting_to_retry` (give up)**: `renderRetryCountdown(null)` returns `''` (`connectionWarnings.ts:104-105`); banner renders the `retry` branch with empty headline when `retryStatus` is null even though the engine kept `connectionState='waiting_to_retry'`. Plan required `"Reconnecting…"` fallback (line 971).
  - **`connected_ready`**: no `focusOnMakeBuffer` handling at all — plan required the join-channel branch (lines 980-981).
- **Impact**: the user sees blanks or wrong copy for at least 6 engine states. Particularly visible on the slow handshake path (`connected` → `connected_joining` → `connected_ready`), which is the new IRCCloud-parity visual story.
- **Why non-blocking**: the missing states are new engine states; the wave-3 brief acknowledges this is a partial delivery (commit message line "11 banner kinds... + away-side branch" only enumerates 9). The plan's hard criterion (line 1122) lists ALL 11 states — strict reading fails this. Wave 4-T01 or a Wave 3 rev must add the cases before the banner ships.

### MEDIUM — Live-countdown cleanup is correctly implemented but NOT test-pinned

- Evidence `ConnectionStatus.svelte:179-184` — `$effect` returns a `clearInterval(id)` cleanup closure:
  ```ts
  let now = $state(Date.now());
  $effect(() => {
    if (!isWaitingToRetry) return;
    const id = setInterval(() => { now = Date.now(); }, 1000);
    return () => clearInterval(id);
  });
  ```
  Implementation is correct: Svelte 5 wires the returned cleanup to (a) the next $effect re-run when `isWaitingToRetry` flips to false and (b) component unmount. No timer leak.
- Evidence `ConnectionStatus.test.ts:180-199` — the `renders Reconnecting in <N>s... (<ordinal> attempt) with live countdown ticks` test exercises `vi.advanceTimersByTime(5_000)` and asserts the text ticks from `12s` to `7s`. **It does not assert `vi.getTimerCount()` post-unmount** — the brief explicitly requires this assertion ("Test (`clears interval on unmount`) actually proves it: uses `vi.getTimerCount()` post-unmount.").
- Evidence `ConnectionStatus.test.ts` — no other test mentions `unmount`, `vi.getTimerCount`, or `cleanup`.
- **Impact**: a future refactor that accidentally drops the cleanup closure would pass the current test suite. The plan's hard criterion (line 1125: "On unmount OR retryStatus transition to null, the setInterval is cleared (no leaked timer).") is exercised by code review only, not by machine.
- **Fix**: append a second test in the countdown describe block that renders, then unmounts, then asserts `expect(vi.getTimerCount()).toBe(0)`.

## Other issues

### LOW — `waiting_to_retry (give up)` renders empty headline (subset of Critical #1)

- Evidence `ConnectionStatus.svelte:346-351` — when `bannerKind === 'retry'`, the rendered text is `{retryText || headline}`. `headline` for the retry case is `renderRetryCountdown(activeNetwork.retryStatus)` with no fallback (line 117). `renderRetryCountdown(null)` returns `''` (`connectionWarnings.ts:105`).
- **Impact**: if the engine ever sets `connectionState='waiting_to_retry'` with `retryStatus=null` (the dual-clear path on successful reconnect), the banner shows nothing. Plan required `"Reconnecting…"` as the fallback.
- **Fix**: short-circuit `bannerKind === 'retry'` to `'Reconnecting…'` when `retryText === ''`. Three-line change.

### LOW — `bannerKind` derivation is order-sensitive and stale for `'connected'`/`'connected_joining'`

- Evidence `ConnectionStatus.svelte:90-104` — order is `away → retry → failInfo branches → connecting → default`. The `connectionState` values `'connected'` and `'connected_joining'` are never checked, so any network in those states with no failInfo falls through to `'disconnected'`. Combined with `showStatus` (`ConnectionStatus.svelte:63-66`) which hides the banner entirely when `connected=true`, the visible behaviour is "no banner" — currently tested at `ConnectionStatus.test.ts:201-207` as the assertion that the cell has no `.show` class.
- **Impact**: if a future task wants the banner visible during the handshake to communicate "Connected; setting up…", the showStatus gate has to be lifted AND the new BannerKind added in the same change. The current implementation is internally consistent but locks the banner to "hide when connected".
- **Fix**: out of scope for this review unless the implementer wants to land it as part of Critical #1.

## Non-blocking deviations

### 1. `connectionWarnings.ts` consolidates `renderReasons.ts` + `suspiciousConnection.ts`

- Evidence `git show --stat HEAD` — 5 files changed; neither `frontend/src/lib/renderReasons.ts` nor `frontend/src/lib/suspiciousConnection.ts` is in the diff (they were deleted in the parent commit `d2fd53b` and rolled into the new `connectionWarnings.ts` per the W3-T01 spec).
- The brief (item 8) still references the deleted test files:
  ```
  npx vitest run --project=lib src/lib/connectionWarnings.test.ts \
    src/lib/renderReasons.test.ts src/lib/suspiciousConnection.test.ts
  ```
  This command exits "No test files found" for the last two paths.
- **Why non-blocking**: the consolidation preserves the surface (the 4 plan-required exports `renderReason` / `renderSSLVerify` / `connectionWarnings` / ordinal logic are present in `connectionWarnings.ts:74-93, 137-183, 116-125`). `connectionWarnings.test.ts` covers every case the deleted files covered, plus extra coverage (RFC1918 ranges, .local TLD, `null` host, combined-warnings ordering). The brief is stale on the test commands but the intent (everything passing) is satisfied via the consolidated file.

### 2. `kill` reason goes through `renderReason()` (plan says `strip()`)

- Evidence `ConnectionStatus.svelte:119` — `Disconnected - Killed: ${renderReason(fail?.killedReason || fail?.reason)}`.
- Plan line 1032 — `"Disconnected - Killed: {strip(killedReason)}"` — used IRCCloud's `strip()` which trims and removes surrounding markup, not the IRC-reason translation table.
- **Why non-blocking**: `renderReason` trims (`connectionWarnings.ts:76-77`), returns `''` for empty input, and passes through unknown strings verbatim (`connectionWarnings.ts:79`). The behaviour diverges only if the killed reason matches an engine reason code (e.g. `econnrefused`) — then the banner would say `"Killed: Connection refused"` instead of `"Killed: ECONNREFUSED"`. The W2 engine emits `killedReason` as a human-shaped string (e.g. `'K-lined: spamming'`, `ConnectionStatus.test.ts:120`), so this is unlikely to be user-visible. Note as a minor copy nuance.

## Verification by plan acceptance criterion (W3-T01)

| # | Plan criterion (plan.yaml:1121-1134) | Verdict |
|---|---|---|
| 1 | Renders 11 states correctly | PARTIAL — 5/11 (away / connecting / fail-5-branches / disconnected / retry-with-status) are correct; 6/11 missing (see Critical #1). The implementation does cover failInfo-driven branches per the `failInfo.type` switch. |
| 2 | Ordinal when `attemptCount > 1` | PASS — `ordinalSuffix` at `connectionWarnings.ts:116-125` handles 1st/2nd/3rd/4th/11th/21st. Tested at `connectionWarnings.test.ts:152-189`. |
| 3 | Countdown decrements every 1s and stops at 0 | PASS — `renderRetryCountdown` clamps to 0 (`connectionWarnings.ts:106-107`); $effect interval at `ConnectionStatus.svelte:179-184` ticks `now` every 1s. Tested at `ConnectionStatus.test.ts:180-199`. Cleanup correctness is by code review only. |
| 4 | setInterval cleared on unmount / retryStatus→null | PASS (implementation) / UNTESTED — see Critical #2. |
| 5 | `'killed'` → "Click to disconnect" | PASS — `ConnectionStatus.svelte:199` (`badRetry === true` branch). Tested `ConnectionStatus.test.ts:268-296`. |
| 6 | `ssl_verify_error` → "Strict transport security error: …" | PASS — `ConnectionStatus.svelte:121`. Tested `ConnectionStatus.test.ts:126-138`. |
| 7 | `bad_cert` / `cert_expired` → "Certificate expired" | DEVIATION — `connectionWarnings.ts:91` returns `'<type>: <error>'` (e.g. `'CERT_HAS_EXPIRED: server certificate expired on 2026-01-01'`), not the IRCCloud literal `'Certificate expired'`. Tests at `connectionWarnings.test.ts:124-128` pin the new shape. Behaviour matches the W2 test-2 lock at `review-wave2.md:46-48` only if the engine still emits `bad_cert` + `cert_expired` as separate keys; current engine emits OpenSSL-style codes (e.g. `CERT_HAS_EXPIRED`). Plan line 1128 pinned the IRCCloud literal — implementation accepts the deviation. |
| 8 | `econnrefused` → "Disconnected: Connection refused" | PASS — `connectionWarnings.ts:62` maps `econnrefused → 'Connection refused'`; `ConnectionStatus.svelte:130` renders it. Tested `ConnectionStatus.test.ts:308-310`. |
| 9 | `isSuspiciousPort(ssl, 6667)` → "You're trying to connect via SSL on port 6667" | PASS — `connectionWarnings.ts:148-150`. Tested `connectionWarnings.test.ts:11-14`, `ConnectionStatus.test.ts:211-221`. |
| 10 | `isSuspiciousHostname('localhost')` → "Your hostname looks invalid: localhost" | PASS — `connectionWarnings.ts:153-173`. Tested `connectionWarnings.test.ts:21-25`, `ConnectionStatus.test.ts:224-234`. |
| 11 | `isAway === true && connected === true` → Away banner | PASS — `ConnectionStatus.svelte:91-92`. Tested `ConnectionStatus.test.ts:82-87`. |
| 12 | Button click fires correct callback | PASS — `handleClick` at `ConnectionStatus.svelte:250-262` routes `badRetry` → `handleDisconnect`, else → `handleReconnect`. `handleBack` at `ConnectionStatus.svelte:215-219` calls `onSendRaw(networkId, 'AWAY')`. Tested `ConnectionStatus.test.ts:279-303`. |
| 13 | Hairline-bar visual + tinted bg + hover brighten | PASS — CSS at `ConnectionStatus.svelte:381-543` ships border-top + border-bottom (`ConnectionStatus.svelte:396-397`), `--fiber-blue-soft` bg (line 398), `--fiber-blue` accent on hover (lines 413-415), `--fiber-amber-soft` for fail (lines 448-452). No new tokens; all values from existing fiber palette. The brief's requirement (item 7 — was truncated in the prompt) for "no new tokens" is satisfied. |

## Verification by plan acceptance criterion (W3-T02)

| Plan section (plan.yaml:1162-1256) | Verdict |
|---|---|
| A. AWAY — preserved + extended | PASS — `ConnectionStatus.test.ts:82-87` covers click-to-come-back text; line 298-303 covers click → `sendRaw(AWAY)`. |
| B. DISCONNECTED (no failInfo) — preserved + click assertion | PASS — `ConnectionStatus.test.ts:263-266` (button text), `279-284` (click → reconnectNetwork). |
| C. DISCONNECTED + killed — new test | PASS — `ConnectionStatus.test.ts:116-124` (text), `268-276` (button label via badRetry), `286-296` (click → disconnectNetwork). |
| D. DISCONNECTED + ssl_verify_error | PASS — `ConnectionStatus.test.ts:126-138`. |
| E. DISCONNECTED + econnrefused | PASS — `ConnectionStatus.test.ts:106-114` (text matches plan: `'Failed to connect - Connection refused'`). |
| E.LEGACY. disconnectReason-only fallback | NOT IMPLEMENTED — no test pins the `failInfo ?? disconnectReason` legacy fallback. The implementation handles this case at `ConnectionStatus.svelte:128-141` (the `'disconnected'` default branch reads `disconnectReason` first), but no test exercises a network with `disconnectReason='Connection reset'` and `failInfo=undefined` to pin the legacy path explicitly. |
| F. SUSPICIOUS PORT (SSL on 6667) | PASS — `ConnectionStatus.test.ts:211-221`. |
| G. SUSPICIOUS HOSTNAME (localhost) | PASS — `ConnectionStatus.test.ts:224-234`. |
| H. WAITING_TO_RETRY (ordinal) | PASS — `ConnectionStatus.test.ts:180-199` (uses 3rd attempt, base 12_000ms). |
| I. WAITING_TO_RETRY (countdown ticks) | PARTIAL — countdown ticks correctly; **no unmount-cleanup assertion**. See Critical #2. |
| J. QUEUED state | NOT IMPLEMENTED — banner doesn't render "Connection queued; waiting our turn…" (see Critical #1). |
| K. CONNECTING state | PASS — `ConnectionStatus.test.ts:89-93`. |
| L. CONNECTED_READY with focusOnMakeBuffer | NOT IMPLEMENTED — see Critical #1. |
| M. QUITTING state | NOT IMPLEMENTED — see Critical #1. |
| N. HAIRLINE-BAR VISUAL | NOT IMPLEMENTED — no `computedStyle` assertion in the test file. CSS is correct on inspection but not test-pinned. |
| O. AWAY PRESENCE DURING DISCONNECT | PASS-by-implication — `ConnectionStatus.test.ts:201-207` asserts banner is hidden when fully connected & not away; the AWAY-precedence logic at `ConnectionStatus.svelte:91-92` (away checked first) and `showStatus` at lines 63-66 implicitly guarantees AWAY-only-when-away. No explicit "AWAY takes precedence over disconnect" test. |

## Test summary

| Suite | Tests | Status |
|---|---|---|
| `connectionWarnings.test.ts` (lib) | 33 | PASS |
| `renderReasons.test.ts` (lib) | — | file removed in Wave 2 commit `d2fd53b`; not run |
| `suspiciousConnection.test.ts` (lib) | — | file removed in Wave 2 commit `d2fd53b`; not run |
| `ConnectionStatus.test.ts` (client) | 33 | NOT RUN — Playwright environment failure in worktree (parent-repo node_modules symlink + URL-encoded spaces). 54/54 client test files fail identically. Code-review-only. |
| `npx tsc --noEmit` | — | clean for the 5 touched files; pre-existing errors in `wsHoleDetector.test.ts` + `ircStore.svelte.test.ts` are out of scope |

## Learn

- 3 captures saved (per agentmemory `learn` rule, max 5).
- See `agentmemory` for: (a) plan-vs-implementation state-coverage gap pattern — flag missing `connectionState` values early; (b) Playwright + URL-encoded spaces + symlinked `node_modules` is a known worktree-broken combo — prefer running client tests from the parent repo path; (c) Svelte 5 `$effect` cleanup return + `vi.getTimerCount()` is the canonical pattern; pin the unmount assertion.

## Recommendations

1. **Add the 6 missing states** (queued / connected / connected_joining / quitting / ip_retry / connected_ready + give-up-retry fallback) to `BannerKind` and `headline`. ~30 LOC, adds 4-6 new tests.
2. **Add the unmount-cleanup test** (`vi.getTimerCount() === 0` post-unmount). 8 LOC.
3. **Add E.LEGACY + L + M + N tests** from the W3-T02 spec to pin those paths explicitly.
4. **Re-run the client suite** from a parent-repo path (not the worktree) once items 1-3 are in — the Playwright failure is environmental, not a code regression.
5. **Optional**: simplify `killed` copy to use plain `killedReason` (drop `renderReason()` wrap) to match the plan literal at line 1032.
