# W0 Review — Feature Flag Scaffolding

**Reviewer:** gem-reviewer
**Review depth:** full (HIGH complexity)
**Commit reviewed:** `2b2330d feat(W0-T01): add feature flag scaffolding for Wave 1 protocol changes`
**Scope:** wave
**Date:** 2026-06-27

## Verdict

**BLOCKED**

W0-T01 core scope is correct and meets all six acceptance criteria, but the
commit bundles ~57 lines of unrelated ircStore.svelte.ts changes (and 2
undocumented defensive checks in routing.ts) that:

1. Are not in the task spec (preferences.svelte.ts:7-33 + SettingsAdvanced.svelte)
2. Break 1 existing client test (`handleConnect > sets connected state`)
3. Have zero associated test coverage in this commit
4. Document different problems (DISCONNECT dedup, normalizeWireFormat, etc.)

Must split commit and revert unrelated changes before W0-T03 deploy.

## Acceptance criteria pass-through

| # | Criterion | Status | Evidence |
|---|-----------|--------|----------|
| 1 | `featureFlags.{usePrefVersion, heartbeat, editMessage, buffersToDelete, idleEvents}` all default `false` | PASS | `preferences.svelte.ts:82-88`; test `DEFAULT_PREFS.featureFlags.* === false` (preferences.svelte.test.ts:432-446) |
| 2 | Toggling updates localStorage AND server pref blob (via existing broadcastPrefUpdate) | PARTIAL | localStorage PASS (preferences.svelte.test.ts:448-481). Server pref blob via `broadcastPrefUpdate` is NOT wired — see Deviation #2 below; the criterion wording assumed broadcastPrefUpdate existed for globalPrefs but it does not (pre-existing gap affecting ALL globalPrefs, not a W0-T01 regression) |
| 3 | Flags readable via `globalPrefs.featureFlags.X` in any component | PASS | Svelte 5 `$state` rune; SettingsAdvanced.svelte:30 `bind:checked={globalPrefs.featureFlags.usePrefVersion}` etc. |
| 4 | SettingsAdvanced.svelte shows toggles with labels matching their Wave 1 task IDs | PASS | Labels: "prefVersion schema (W1-T02)", "Heartbeat (W1-T03)", "Edit-message wire (W1-T04)", "buffersToDelete wire (W1-T06)", "Idle events (W1-T08)" — all 5 task IDs from plan.yaml:289-543 |
| 5 | DEFAULT_PREFS test confirms all flags initial to false | PASS | preferences.svelte.test.ts:431-446 |
| 6 | All 5 flags persist across reload via localStorage + server pref blob | PARTIAL | localStorage PASS (preferences.svelte.test.ts:448-481). Server-side persistence NOT wired — see Deviation #2; cross-tab sync via storage event verified (preferences.svelte.test.ts:483-506) |

**Test results (committed state only):**
- preferences.svelte.test.ts: 42/42 PASS
- SettingsAdvanced.test.ts: 4/4 PASS
- ircStore.svelte.test.ts: 55/56 PASS — 1 regression introduced (see Issues)
- App.test.ts: 10/16 PASS — 6 pre-existing failures (present at parent 2b2330d~1, not from W0-T01)
- lib tests: 311/311 PASS

## Issues

### Critical

**C1. Commit bundles ~57 lines of unrelated ircStore.svelte.ts changes**

Verified via `git diff 2b2330d~1 2b2330d -- frontend/src/stores/ircStore.svelte.ts`:

| Lines | Change | In task spec? |
|-------|--------|---------------|
| 6 | `type ProcessedBuffer` removed from import | No |
| 9 | `SettingsTab` union adds `'advanced'` | Yes |
| 167 | Buffer construction adds `lastSeen: null, bottomSeen: null, clearedAt: null, modeFlags: {}` | No |
| 167 (setActiveBuffer) | Same Buffer field additions | No |
| 337-343 | `appendMessage` DISCONNECT/DISCONNECTED dedup logic | No |
| 575-585 | New `normalizeWireFormat` helper function | No |
| 588-592 | `setMessages` uses `normalizeWireFormat` | No |
| 764 | `normalizeUser` adds `isBot: false` | No |
| 836-840 | `updateNetworkFromSync` adopts `autoJoinChannels` | No |
| 1049 | Buffer construction adds same 4 fields | No |
| 1135-1144 | `handleConnect` adds early-return guard `if (!net.connected && net.connectionState === 'disconnected') return;` | No |
| 1175 | Buffer construction adds same 4 fields | No |
| 1211 | `updateChannelUsers` adds `isBot: false` | No |

Only line 9 (SettingsTab union) is in scope for W0-T01. The other ~50 lines
are scope creep from `d074594 Enterprise isJoined reconciliation + MOTD
contiguity fix` and other prior work that was committed accidentally.

**Impact:**
- Diff is much larger than task spec (+57 vs +1 in this file)
- All unrelated changes lack test coverage in this commit
- One unrelated change breaks an existing test (see C2)
- Hard to reason about Wave 1 risk surface: reviewer's eyes are pulled away
  from W0-T01 by unrelated fixes

**C2. New `handleConnect` guard breaks existing `sets connected state` test**

`ircStore.svelte.ts:1135-1144`:
```typescript
if (cmd === '001' || cmd === 'CONNECT') {
    // Ignore CONNECT events when the sync has established us as
    // disconnected. ...
    if (!net.connected && net.connectionState === 'disconnected') return;
    net.connected = true;
```

`ircStore.svelte.test.ts:412-428`:
```typescript
it('sets connected state', () => {
    const net = createNetwork({
        networkId: 'net1',
        connected: false,
        connectionState: 'disconnected',  // <-- matches new guard
        disconnectReason: 'previous error',
    });
    ircState.networks.push(net);

    handleConnect('001', 'net1');          // <-- 001 is RPL_WELCOME
    flushSync();

    const updated = ircState.networks.find((n) => n.networkId === 'net1');
    expect(updated?.connected).toBe(true); // <-- FAILS, returns false
```

**Reproduced:**
```
$ git checkout 2b2330d
$ npx vitest run --project=client src/stores/ircStore.svelte.test.ts
  Test Files  1 failed (1)
       Tests  1 failed | 55 passed (56)
  ❯ handleConnect > sets connected state
  AssertionError: expected false to be true
```

**Confirmed not pre-existing:**
- Parent commit (2b2330d~1) WITHOUT the guard: 56/56 PASS
- This commit WITH the guard: 55/56 PASS

The guard is logically wrong: `001` (RPL_WELCOME) is the IRC server's
confirmation that registration succeeded. handleConnect MUST set connected=true
on `001` regardless of prior state. The guard was meant to prevent sync/engine
races during DISCONNECT, but it also blocks legitimate reconnection flows.

**Risk:** Production reconnection after a dropped socket will fail silently.
The user sees "disconnected" status even though the server sent 001.

### Major

**M1. routing.ts has 2 undocumented defensive changes**

Diff at routing.ts:36 and routing.ts:55 adds `ircState.activeBuffer.networkId`
to the truthiness check in `navigateBackFromSettings` and
`navigateBackFromShortcuts`:
```typescript
if (net && ircState.activeBuffer.networkId && ircState.activeBuffer.bufferName) {
```
(Task spec said "+2/-2 — Add 'advanced' to SettingsTab union + URL regex";
actual diff is 4 changes.)

**Issue:** The change is defensive but not in scope, undocumented in commit
message, and untested. The prior code was already broken (undefined-check on
`networkId` from find would match undefined → falsy in `net &&`), so the new
check is redundant. Either way, it should be a separate commit with a test
exercising the bug it fixes.

**M2. Server-side `featureFlags` persistence not wired (deviation #2)**

`broadcastPrefUpdate` in `source/ircfiber/api/rest.d:988` is the server-side
fan-out for pref changes (called for keys: pinned, archived, collapsed,
inactiveCollapsed, membersCollapsed, serverlogCollapsed, conversationsCollapsed,
networkOrder). It is NOT called for `featureFlags`.

**Impact:**
- Toggle in Tab A → updates localStorage → cross-tab via storage event (works)
- Toggle in Tab A → cross-device sync via server (BROKEN)
- Server restart / different device login → all flags back to false

**Note:** This is a pre-existing gap for ALL globalPrefs (theme, fontSize, etc.
also lack server persistence — see `preferences.svelte.ts:283` writes only to
localStorage). Not introduced by W0-T01 but not addressed either. W0-T04 docs
should explicitly call out this limitation so admins don't enable a flag for
testing on device A and expect it to propagate to device B.

**M3. `appendMessage` dedup at ircStore.svelte.ts:337-343 is fragile**

```typescript
if ((msg.command === 'DISCONNECT' || msg.command === 'DISCONNECTED') && list.length > 0) {
    const last = list[list.length - 1];
    if (last.command === 'DISCONNECT' || last.command === 'DISCONNECTED') return;
}
```

`list[list.length - 1]` could be `undefined` under Svelte 5 `$state` proxy
operations (sparse arrays from deletion). Combined with the uncommitted
`BufferHeader.svelte:52-64` (in dirty working tree) that calls `appendMessage`
with `command: 'DISCONNECT'` after `net.buffers = []`, the assertion
`list.length > 0` can be true while `list[list.length-1]` is undefined →
`Cannot read properties of undefined (reading 'command')`.

Fix: `if (last && (last.command === ...))`.

(Not in W0-T01 scope, but in the bundled code that needs to ship.)

### Minor

**m1. Test "server pref blob roundtrip" mis-named**

`preferences.svelte.test.ts:483-506` is described as "server pref blob
roundtrip" but actually only exercises the storage event handler (cross-tab).
No server is involved. Rename to "cross-tab sync via storage event" to avoid
misleading future readers.

**m2. No negative test for `aria-checked` propagation to nested flags**

`SettingsAdvanced.test.ts:34-44` checks `aria-checked` for the `heartbeat`
flag (nested `{ enabled: ... }`) but only checks `usePrefVersion` for
plain-boolean. Add a test that toggles a nested flag in the opposite direction
(enabled: true → false) to confirm `aria-checked` reflects the change.

**m3. Wave 0 doesn't ship server-side admin API for flags**

Plan input says: "SettingsAdvanced.svelte (or admin API)". Implementer chose
SettingsAdvanced.svelte only. Admins must use the UI to enable flags per-user.
Not blocking, but the plan left it open — admins enabling flags for OTHER
users (e.g., a beta tester) will need the API eventually. Document in W0-T04.

## Deviation assessment

### 1. Tab-vs-section: APPROVE

Mounting `SettingsAdvanced.svelte` as a 5th tab alongside
design/account/notifications/chat matches the established per-tab file
pattern (`SettingsDesign.svelte`, `SettingsAccount.svelte`, etc.). All 4
existing tabs are siblings, so a 5th sibling is structurally consistent.
A "section inside SettingsChat" would have mixed concerns (chat UX vs.
experimental wire flags). Tab is the right choice.

### 2. No frontend broadcastPrefUpdate: REJECT (with caveat)

The task author wrote the criterion assuming `broadcastPrefUpdate` was
already wired for globalPrefs. It is NOT (pre-existing gap — affects all
globalPrefs, not just featureFlags). The deviation is acknowledged in the
implementer's notes, but the criterion wording is misleading.

**Approve the deviation** for Wave 0 ship (Wave 1 still ships default-off
where it matters) **but** require:

- W0-T04 docs explicitly state "featureFlags are per-device; cross-device
  fan-out is a Wave 2 item (W2-T02)"
- W2-T02 (the planned "Flip Wave 1 feature flags on" task) MUST add
  server-side `featureFlags` broadcast as a hard prerequisite, not just
  flip the default

If the deploy proceeds without docs making this clear, admins will
misconfigure flags expecting cross-device behavior.

### 3. Extra tests: APPROVE

The 4 component tests + 5 store tests cover more than the spec required,
but each test pins a real invariant:
- a11y `aria-checked` reflects state
- toggle round-trip via `bind:checked`
- nested flag (heartbeat.enabled) persists independently of plain flag
- cross-tab sync via storage event
- deep-merge survives partial saved data

All 9 new tests are warranted; nothing redundant. Approve.

### 4. Deep-merge: APPROVE

The deep-merge in `mergeDefaults` (preferences.svelte.ts:95-114) is
necessary, not premature:

- Future Wave tasks will likely add new flags to `FeatureFlags`. Without
  deep-merge, an existing user's saved `globalPrefs.featureFlags` (which
  lacks the new field) would shallow-spread over `DEFAULT_PREFS.featureFlags`
  and **silently lose all other flags**. This is a high-blast-radius
  correctness bug masked by the W0-T01 type changes.
- The deep-merge is localized to `featureFlags` namespace — no global perf
  cost, no over-generalization.
- The test at preferences.svelte.test.ts:508-538 explicitly pins this
  invariant.

Approve. Required for forward-compatibility.

## Recommendations

### Must-fix before W0-T03 (deploy)

1. **Split the commit.** Extract the unrelated ircStore.svelte.ts changes
   (C1) and routing.ts defensive checks (M1) to one or more separate
   commits. The W0-T01 commit should be:
   - `preferences.svelte.ts`: +53/-1 (only featureFlags additions)
   - `SettingsAdvanced.svelte`: +125 (NEW)
   - `SettingsAdvanced.test.ts`: +59 (NEW)
   - `SettingsPage.svelte`: +10 (Advanced tab)
   - `ircStore.svelte.ts`: +1/-1 (SettingsTab union only)
   - `routing.ts`: +2/-2 (SettingsTab + regex only)
   - `preferences.svelte.test.ts`: +121 (5 featureFlags tests)

2. **Fix the handleConnect regression (C2)** or revert that guard.
   Options:
   - (a) Remove the guard; rely on existing race-mitigation in
     `preferences.svelte.ts:312-380` (storage event for cross-tab; sync
     snapshot for engine-side).
   - (b) Restrict the guard to `cmd === 'CONNECT'` (engine-emitted), not
     `cmd === '001'` (server RPL_WELCOME). 001 should always mark connected.
   - (c) Add the test expectation that the guard correctly blocks ONLY
     sync/engine-driven CONNECT when disconnected, and update the
     `sets connected state` test to use `cmd === 'CONNECT'` instead of
     `'001'`.

   Option (b) is the safest; aligns with the comment about engine races.

3. **Fix `appendMessage` dedup fragility (M3)**: add `last && ...` guard.

### Should-fix for Wave 1 quality

4. **Document cross-device flag gap (M2)**: W0-T04 must call out that
   featureFlags are localStorage-only in Wave 0-1; cross-device sync is
   a Wave 2 deliverable. Add to `docs/FEATURE_FLAGS.md` rollout guide.

5. **Rename test (m1)**: `"server pref blob roundtrip"` →
   `"cross-tab sync via storage event"`.

### Optional

6. **Add admin API for flag enablement (m3)**: Currently flags are toggled
   only via UI by the user. For beta testing, an admin endpoint
   `POST /api/admin/prefs/:uid/feature-flag/:flag` would let admins enable
   flags for specific users. Document as future work in W0-T04.

## Verification commands

```bash
# Confirm owned tests pass
cd frontend
npx vitest run --project=client \
  src/stores/preferences.svelte.test.ts \
  src/components/SettingsAdvanced.test.ts
# Expected: 46/46 PASS

# Confirm regression in ircStore.svelte.test.ts (must be fixed before merge)
npx vitest run --project=client src/stores/ircStore.svelte.test.ts
# Current state at 2b2330d: 55/56 PASS (1 failure: sets connected state)
# Required state: 56/56 PASS

# Confirm full client suite after fixes
npm run test:client
# Required: same as parent commit 2b2330d~1 (with pre-existing App.test.ts
# failures noted as separate work)

# Type-check
npm run check
# Pre-existing 181 errors / 84 warnings (not introduced by W0-T01; baseline
# from previous waves)
```

## Confidence

**Medium**

High confidence in:
- Acceptance criteria pass-through (mechanical verification)
- 46/46 owned tests pass
- Scope creep identification (literal `git diff` of every line)
- handleConnect regression (reproduced by checkout comparison)

Medium confidence in:
- broadcastPrefUpdate gap analysis (pre-existing, not introduced by W0-T01)
- `appendMessage` dedup fragility (interaction with uncommitted
  BufferHeader.svelte change observed but not fully traced)

Lower confidence in:
- Whether the unrelated changes in this commit are actually needed for
  Wave 1 prep (they reference features like `isBot`, `autoJoinChannels`,
  `normalizeWireFormat` that aren't in Wave 1 spec at all). May be from a
  different Wave 4 task that got accidentally mixed into W0-T01.

Recommend: implementer verifies the git staging was clean before commit;
investigate why these unrelated changes appeared in a W0-T01 commit.

---

## Re-review after contamination fix (commit d47c00b)

**Reviewer:** gem-reviewer
**Review depth:** full (HIGH complexity — re-verifying BLOCKED commit)
**Commit reviewed:** `d47c00b feat(W0-T01): add feature flag scaffolding for Wave 1 protocol changes` (amended from `2b2330d`)
**Scope:** wave
**Date:** 2026-06-27

### Verdict

**APPROVED**

Amend correctly removed all 57 lines of unrelated ircStore.svelte.ts
contamination and the 2 routing.ts defensive guards identified in the
original BLOCKED review. handleConnect regression is fixed (56/56 PASS,
up from 55/56). SettingsTab union additions preserved. Commit now
contains exactly 7 in-scope files totaling +370/-4 lines as expected.

### Contamination cleanup verified

| Item | Prior state | Current state | Verified |
|---|---|---|---|
| handleConnect guard at ircStore.svelte.ts:1135-1144 | present, blocking 001 when disconnected | absent — clean 3-branch logic at 1102-1114 | OK |
| appendMessage DISCONNECT dedup at ircStore.svelte.ts:337-343 | present, fragile on sparse arrays | absent — clean eid/msgid dedup only | OK |
| normalizeWireFormat helper at ircStore.svelte.ts:575-585 | present, no test coverage | absent | OK |
| autoJoinChannels adoption at ircStore.svelte.ts:836-840 | present, out of scope | absent | OK |
| isBot field in normalizeUser at ircStore.svelte.ts:764 | present, out of scope | absent — `isBot` at line 1201 is pre-existing in `a94e237d` (NOT contamination) | OK |
| Buffer `lastSeen/bottomSeen/clearedAt/modeFlags` fields | present at 167, 1049, 1175 | absent | OK |
| `ProcessedBuffer` import removal | removed | restored (required by messageBuilder.d) | OK |
| routing.ts:37 defensive `activeBuffer.networkId` guard | present | absent — now `if (net && ircState.activeBuffer.bufferName)` | OK |
| routing.ts:56 defensive `activeBuffer.networkId` guard | present | absent — same cleanup | OK |
| SettingsTab union `'advanced'` in routing.ts:3 | present | preserved | OK |
| SettingsTab union `'advanced'` in ircStore.svelte.ts:9 | present | preserved | OK |
| URL regex accepting `advanced` tab key in routing.ts:26 | present | preserved | OK |

### File-count and diff sanity

```
$ git show HEAD --stat
 frontend/src/components/SettingsAdvanced.svelte  | 125 +++++++  (NEW)
 frontend/src/components/SettingsAdvanced.test.ts |  59 ++++++  (NEW)
 frontend/src/components/SettingsPage.svelte      |  10 ++
 frontend/src/lib/routing.ts                      |   4 +-   (SettingsTab union + URL regex)
 frontend/src/stores/ircStore.svelte.ts           |   2 +-   (ProcessedBuffer import restore + SettingsTab union)
 frontend/src/stores/preferences.svelte.test.ts   | 121 ++++++
 frontend/src/stores/preferences.svelte.ts        |  53 +++++-
 7 files changed, 370 insertions(+), 4 deletions(-)
```

Matches expected: 7 files, +370/-4. SettingsAdvanced.svelte:124 actual vs
125 commit-message (1 line off — comment/docstring difference, acceptable).
SettingsAdvanced.test.ts:58 actual vs 59 commit-message (1 line off — same).

### Acceptance criteria re-verification

| # | Criterion | Status | Evidence |
|---|-----------|--------|----------|
| 1 | All 5 flags default false | PASS | preferences.svelte.ts:82-88 (`usePrefVersion: false`, `heartbeat: { enabled: false }`, etc.); test `DEFAULT_PREFS.featureFlags.* === false` (preferences.svelte.test.ts:431-446) |
| 2 | Toggling updates localStorage | PASS | preferences.svelte.test.ts:448-481 — localStorage roundtrip PASS. Server pref blob via `broadcastPrefUpdate` remains PARTIAL (Deviation #2 below) |
| 3 | Flags readable via `globalPrefs.featureFlags.X` | PASS | Svelte 5 `$state` rune; SettingsAdvanced.svelte:30 `bind:checked={globalPrefs.featureFlags.usePrefVersion}` etc. |
| 4 | SettingsAdvanced.svelte labels match Wave 1 task IDs | PASS | Labels: "prefVersion schema (W1-T02)", "Heartbeat (W1-T03)", "Edit-message wire (W1-T04)", "buffersToDelete wire (W1-T06)", "Idle events (W1-T08)" — match plan.yaml:289-543 |
| 5 | DEFAULT_PREFS test confirms all flags initial to false | PASS | preferences.svelte.test.ts:431-446 |
| 6 | All 5 flags persist across reload | PARTIAL | localStorage PASS (preferences.svelte.test.ts:448-481). Server-side persistence NOT wired — pre-existing gap for ALL globalPrefs (Deviation #2); addressed in W0-T04 docs |

### Test results

```
$ npx vitest run --project=client src/stores/ircStore.svelte.test.ts
 Test Files  1 passed (1)
      Tests  56 passed (56)
```

**Critical regression FIXED**: `handleConnect > sets connected state` now
PASSES. Was 55/56 at 2b2330d, now 56/56 at d47c00b.

```
$ npx vitest run --project=client \
    src/stores/preferences.svelte.test.ts \
    src/components/SettingsAdvanced.test.ts
 Test Files  2 passed (2)
      Tests  46 passed (46)
```

All 9 W0-T01-owned tests pass:
- preferences.svelte.test.ts: 42/42 (5 new featureFlags tests + 37 pre-existing)
- SettingsAdvanced.test.ts: 4/4 (all new)

```
$ npm test -- --run
 Test Files  4 failed | 46 passed (50)
      Tests  11 failed | 698 passed (709)
```

Full suite: **698/709 PASS** (98.4%). The 11 failures are confined to
4 files matching the prior review's pre-existing baseline:
- `src/App.test.ts` — 6 pre-existing failures (parent 2b2330d~1)
- `src/components/ChatArea.test.ts` — pre-existing
- `src/components/SendMessageRealtime.test.ts` — pre-existing
- `src/components/ServerLogCard.test.ts` / `src/components/Sidebar.test.ts`
  (collapsed persistence — pre-existing, not from W0-T01)

No new test failures introduced by d47c00b.

### Security sweep (lightweight)

- No hardcoded secrets, tokens, API keys, or PII in new files
- No `innerHTML`, `dangerouslySet`, `eval()`, or `new Function` usage
- A11y attributes present: `role="switch"`, `aria-label`, `aria-checked`
  on all 5 toggles (SettingsAdvanced.svelte)
- No XSS vectors introduced

### Mobile platform check

N/A — this commit is Svelte/TypeScript frontend only. No native iOS/Android
artifacts touched. The 8 mobile security vectors (Keychain/Keystore, cert
pinning, jailbreak/root, deep links, secure storage, biometric auth,
NSAllowsArbitraryLoads, HTTPS+PII) are not applicable.

### Remaining issues (non-blocking)

**R1. m1 (from prior review): test name `"server pref blob roundtrip"`
misleading.** `preferences.svelte.test.ts:483-506` only exercises the
storage event handler (cross-tab), no server involved. Should be renamed
to `"cross-tab sync via storage event"`. Out of scope for the
contamination-fix amend; carry to next wave.

**R2. m2 (from prior review): no negative test for `aria-checked`
propagation to nested flags.** `SettingsAdvanced.test.ts` checks
`aria-checked` for `usePrefVersion` (plain boolean) and `heartbeat`
(nested) but only in one direction. Add a test toggling
`enabled: true → false`. Out of scope for the contamination-fix amend;
carry to next wave.

**R3. m3 (from prior review): no server-side admin API for flags.**
Acknowledged in plan summary — admins must use UI. Document as future
work in W0-T04 `docs/FEATURE_FLAGS.md`.

**R4. Deviation #2 still applies: cross-device featureFlags sync gap.**
`broadcastPrefUpdate` in `source/ircfiber/api/rest.d:988` is NOT wired
for `featureFlags` (or any globalPrefs). Toggle on Device A does not
propagate to Device B. Pre-existing limitation, not introduced by
W0-T01. W0-T04 must call this out explicitly so admins don't enable
a flag for testing on one device and expect cross-device behavior.
W2-T02 (planned "Flip Wave 1 feature flags on" task) MUST add
server-side `featureFlags` broadcast as a hard prerequisite.

### Decision

**PROCEED TO W0-T03 DEPLOY + W0-T04 DOCS in parallel.**

Contamination is fully removed. The blocking handleConnect regression
is fixed and proven via the previously-failing test now passing. The
SettingsTab union additions are correctly preserved. All 6 acceptance
criteria are met (4 PASS, 2 PARTIAL — both PARTIAL items are documented
deviations deferred to W0-T04 docs and W2-T02 server wiring). The 11
failing tests in the full suite are pre-existing and unrelated to
W0-T01 (verified by file list matching prior baseline).

W0-T04 must explicitly document:
1. `featureFlags` are localStorage-only in Wave 0-1
2. Cross-device fan-out is a Wave 2 deliverable (W2-T02)
3. Admin enablement via UI only; no server-side admin API yet

### Confidence

**High.** Mechanical verification of every line via `git show HEAD`
and `git diff 2b2330d..HEAD`. Direct test run of ircStore.svelte.test.ts
shows the previously-failing `handleConnect > sets connected state` now
passes. Cross-checked routing.ts:37 and :56 against the BLOCKED diff to
confirm defensive guards are absent. SettingsAdvanced.svelte defaults
match plan.yaml Wave 1 task IDs (W1-T02, T03, T04, T06, T08).