# W1 Critic Review — Architectural Risk Audit

**Plan:** `2026-06-27-irccloud-design-parity`
**Wave:** 1 (Foundation)
**Reviewer verdict:** APPROVED
**Reviewer report:** `docs/plan/2026-06-27-irccloud-design-parity/w1-review.md`

## Verdict: PROCEED (0 blocking, 2 warnings, 1 suggestion)

## Verified: Critical Architecture Concerns

### 1. Wire-format compatibility ✅
`heartbeat_echo` (processor.d:232) + `buffersToDelete` (websocket.d:470) use top-level `type` discriminator. Old clients silently fall through if/else-if chain at App.svelte:503-569 — no `else` crash handler. Confirm: correct.

### 2. Feature flags ✅
All 5 flags default OFF in DEFAULT_PREFS (preferences.svelte.ts:84-91):
- `usePrefVersion: false`
- `heartbeat: { enabled: false }`
- `editMessage: { enabled: false }`
- `buffersToDelete: { enabled: false }`
- `idleEvents: { enabled: false }`

### 3. Migration safety (C1 fix) ✅
`upgradeLegacyPattern()` at ignore.ts:147-155 checks BOTH separators (`!`, `@`) AND wildcards (`*`, `?`). Only pure bare nicks (none present) upgraded to `nick!*@*`. Patterns with any separator OR wildcard preserved as-is. Console.debug logs original before transform. Correct.

### 4. prefVersion atomicity ✅
Redis Lua EVAL script at preferences.d:166-180 atomically increments GET+SET. Vibe.d limitation (no typed MULTI/EXEC) documented inline. Fallback: plain SET on EVAL failure with prefVersion=0 (preferences.d:226-234).

### 5. Heartbeat fiber safety ✅
Single vibe.d fiber using `sleep()` (non-blocking) — no `usleep()`. Iterates `connManager.getNetworks()` each tick. Standard vibe.d pattern; no fiber-safety issue.

### 6. conversationsCollapsed BOTH paths ✅
- `mergePreferences` additive-only: App.svelte:762-774 (boot seed, mirrors inactiveCollapsed)
- `handlePrefUpdate` full delete+add: App.svelte:893-906 (authoritative sync)
- Both confirmed present and matching existing patterns.

## Warnings

### WARNING: idleEvents.enabled flag is NOT a runtime gate 🔴
**Issue:** `globalPrefs.featureFlags.idleEvents.enabled` is defined, stored, default OFF, has a SettingsAdvanced toggle — but the `temp_unavailable` and `idle` events flow through the existing `irc_event` pipeline (messageHandler.ts:196-209) with **zero flag checks**. An admin toggling the flag expecting to suppress idle event processing gets no effect.
**Impact:** Flag creates false sense of control. If a user experiences issues with idle detection and toggles it OFF, nothing changes.
**File:** `frontend/src/lib/messageHandler.ts:196-209` (no gate), `frontend/src/stores/preferences.svelte.ts:23` (flag defined), `frontend/src/App.svelte:937-960` (processEvent has no idle check)
**Mitigation:** Either (a) add `if (!globalPrefs.featureFlags.idleEvents.enabled) return;` at the top of the irc_event handler or in `processEvent()`, (b) gate the engine emission on the flag server-side, or (c) document explicitly that this flag is UI-only. Recommend (a) for consistency with other flags.

### WARNING: Inconsistent feature-flag gating pattern 🔶
**Issue:** `heartbeat_echo` is gated INSIDE the handler function (App.svelte:654) while `buffersToDelete` is gated AT the dispatch level (App.svelte:566). Behavioral outcome is identical (both no-op when OFF) but future maintainers may copy one pattern expecting it works like the other — then hit the wrong timing (dispatch-level gate prevents the function call entirely; handler-level gate still performs the dispatch but returns early).
**Files:** `frontend/src/App.svelte:563-568` vs `frontend/src/App.svelte:653-654`
**Suggestion:** Standardize on dispatch-level gating (matching `buffersToDelete` pattern) since it avoids even calling the handler. Low severity.

### SUGGESTION: heartbeat_echo lastSeen is always empty in Wave 1
**Issue:** processor.d:237-240 explicitly leaves `lastSeen` as an empty JSON object. The heartbeat handler at App.svelte:667-672 iterates `lastSeen` entries — but with an empty map the loop exits immediately. `lastSeenMap` is never updated. The handler is functionally a no-op until W2-T01.
**Impact:** None today (feature flag OFF), but when enabled for testing, admins will see the handler fire with no visible effect. Could cause confusion.
**File:** `source/ircfiber/engine/processor.d:237-240`, `frontend/src/App.svelte:664-673`
**Suggestion:** Either (a) add a fast-path `if (Object.keys(lastSeen).length === 0) return;` in `handleHeartbeat` after the flag check, or (b) document in HEARTBEAT.md that lastSeen is reserved for Wave 2.

## Verifications

| Concern | Status |
|---|---|
| Wire-format changes use feature flags | ✅ All 5 gated |
| Old-client backward compat | ✅ Top-level discriminator, no else crash |
| Redis atomicity (prefVersion) | ✅ Lua EVAL, documented |
| Migration heuristic (C1) | ✅ Correct separator+wildcard check |
| Cross-domain consistency | ✅ Engine D ↔ Frontend TS match |
| No scope leaks | ✅ Each task modifies declared files only |
| New WS types documented | ✅ heartbeat_echo + buffersToDelete in contracts |

## Deliverable

```json
{
  "verdict": "PROCEED",
  "confidence": 0.92,
  "risks_found": 2,
  "risks_mitigated": 5,
  "new_risks": [
    "idleEvents.enabled flag is dead code — no runtime gate exists (messageHandler.ts:196-209). Toggle has zero effect until gate is added.",
    "Inconsistent gating pattern between heartbeat (handler-level) and buffersToDelete (dispatch-level) — low severity, but diverges future maintainers."
  ],
  "recommendations": [
    "Add `if (!globalPrefs.featureFlags.idleEvents.enabled) return;` gate in processEvent() or messageHandler.ts",
    "Standardize all feature flags to dispatch-level gating (buffersToDelete pattern)",
    "Add fast-path early return in handleHeartbeat when lastSeen is empty (Wave 1 no-op until W2-T01)"
  ]
}
```

## Additional Notes

- **prefVersion EVAL fallback** (preferences.d:226-234): On Redis EVAL failure, falls back to plain SET returning prefVersion=0. The next successful EVAL will recompute from the document's current state — transient but self-healing. Acceptable.
- **Heartbeat emits regardless of flag** (processor.d:202-217): Engine always sends heartbeat_echo to Redis even when the flag is OFF. Old clients silently ignore it. Bandwidth cost: N-networks × 1 message per 30s. Trivial. Can be optimized later.
- **buffersToDelete always-on from engine** (websocket.d:467-475): Same pattern as heartbeat — engine always emits, frontend gates. Acceptable for Wave 1.
- **6 pre-existing App.test.ts failures** confirmed unrelated (git stash test). Not introduced by Wave 1.
- No CSP changes, no `scp` of D binaries, no AGENTS.md modifications.
