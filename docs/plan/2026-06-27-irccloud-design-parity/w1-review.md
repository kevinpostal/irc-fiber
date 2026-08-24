# W1 Review — Foundation (8 protocol items)

## Verdict
APPROVED

## Per-task pass-through

- W1-T01 (conversationsCollapsed): ✅
  - Present in BOTH mergePreferences (line 762-774, additive-only) AND handlePrefUpdate (line 893-906, full delete+add)
  - Mirrors inactiveCollapsed pattern exactly
  - Tests: `mergePreferences seeds conversationsCollapsed from stat_user payload` ✓, `handlePrefUpdate applies conversationsCollapsed from WS sync` ✓
- W1-T02 (prefVersion): ✅
  - Redis Lua EVAL atomic increment (source/ircfiber/db/preferences.d:155-185)
  - Last-write-wins in mergePreferences (strictly-greater gate at App.svelte:687)
  - prefVersion tracked in handlePrefUpdate too (App.svelte:817-819)
  - docs/PREF_VERSION.md exists and complete
  - Tests: 3 prefVersion tests all pass (lower/same/higher)
- W1-T03 (heartbeat_echo): ✅
  - WS type `heartbeat_echo` as top-level discriminator (NOT overloaded on irc_event)
  - Gated behind `globalPrefs.featureFlags.heartbeat.enabled` (App.svelte:654)
  - Engine emits ONE batched event per network per 30s (source/ircfiber/engine/processor.d:158-245)
  - Payload shape: `{ type, cid, bid[], ts, lastSeen{} }` - correct
  - Input validation: cid=string, bid=Array, lastSeen=object (App.svelte:658)
  - Old clients silently ignore (falls through if/else chain with no else)
  - Tests: 4 heartbeat tests pass (flag OFF/ON, two networks, atomic update)
- W1-T04 (edit-message): ✅
  - Ctrl/Cmd+Up binding in InputArea.svelte, gated behind `globalPrefs.featureFlags.editMessage.enabled`
  - Engine: `draft/edit-message` cap negotiated in connection.d:60, `sendEditMessage()` at connection.d:2356-2367
  - WS handler at websocket.d:685-697 (`case "editmsg"`)
  - 16 InputArea tests pass including `sends edit message via onSendEditMessage`
- W1-T05 (getDisplayName/safeChanSuffix): ✅
  - Pure function in frontend/src/lib/utils.ts:229, null-safe (returns input unchanged)
  - D-side parser in source/ircfiber/irc/parser.d:1004-1008 (`parseIsupportPrefix`)
  - Non-test files: frontend/src/lib/utils.ts (+55 lines), source/ircfiber/irc/parser.d (+53 lines)
  - 93 utils tests pass including getDisplayName variants
- W1-T06 (buffersToDelete): ✅
  - WS type `buffersToDelete` as top-level discriminator
  - Gated behind `globalPrefs.featureFlags.buffersToDelete.enabled` (App.svelte:566)
  - Engine emits after sync on resume (websocket.d:467-472)
  - Frontend guard: activeJoinList + archivedMap + pinnedMap + hiddenChannelsMap (ircStore.svelte.ts:351-379)
  - Format: `bid[]` = `networkId:bufferName` strings
  - 62 ircStore tests pass including flag OFF/ON and activeJoinList guard
- W1-T07 (IgnoreMap): ✅
  - 3-level map (host→user→nick) ported from IRCCloud ignore.js
  - C1 migration heuristic: checks BOTH separators (!, @) AND wildcards (*, ?)
  - Pure bare nicks ONLY upgraded to `nick!*@*` (ignore.ts:148-154)
  - console.debug shows original pattern before transform (ignore.ts:151)
  - Patterns with !, @, *, ? preserved as-is
  - docs/IGNORE_MIGRATION.md exists and complete
  - 20 ignore tests pass
- W1-T08 (temp_unavailable/idle): ✅
  - Engine emits temp_unavailable (with countdown_ms + serverTs) and idle (with since_ms)
  - parser.d: tags parsed at irc_event.d:92-99, frontend messageHandler.ts:197-208
  - BufferHeader countdown with 1s tick, anchored on expireAt (serverTs + countdown_ms)
  - Feature flag `idleEvents.enabled` exists in preferences, defaults OFF, toggle in SettingsAdvanced
  - 16 BufferHeader tests pass, 62 ircStore tests pass

## Cross-task checks

- **Wire-format compat**: ✅
  - All new WS types (`heartbeat_echo`, `buffersToDelete`) use `type` as top-level discriminator
  - Engine side confirms: `payload["type"] = Json("heartbeat_echo")` at processor.d:232, `btd["type"] = Json("buffersToDelete")` at websocket.d:470
  - Old clients silently ignore unknown types via `if/else if` chain — no `else` crash handler
- **Feature flags**: ✅
  - All 5 flags (`usePrefVersion`, `heartbeat.enabled`, `editMessage.enabled`, `buffersToDelete.enabled`, `idleEvents.enabled`) defined in GlobalPrefs
  - DEFAULT_PREFS sets all to false
  - localStorage persist and server pref blob sync tested
  - SettingsAdvanced.svelte toggles for each flag with W1 task labels
  - Minor note: `idleEvents.enabled` flag is defined but not used as a runtime gate in the processing path (temp_unavailable/idle go through existing irc_event pipeline)
- **M2 fix (W1-T01)**: ✅
  - `conversationsCollapsed` in mergePreferences: additive-only (no delete), mirrors inactiveCollapsed at App.svelte:762-774
  - `conversationsCollapsed` in handlePrefUpdate: full delete+add, mirrors inactiveCollapsed at App.svelte:893-906
- **C1 fix (W1-T07)**: ✅
  - `upgradeLegacyPattern` checks BOTH `pattern.includes('!') || pattern.includes('@')` AND `pattern.includes('*') || pattern.includes('?')`
  - Only pure bare nicks (no separators, no wildcards) upgraded to `pattern + '!*@*'`
  - `console.debug('[Ignore] upgrading bare nick pattern:', pattern)` before transform
- **CSP**: ✅
  - No changes to `deploy/roles/caddy/templates/Caddyfile.j2`
  - No new `unsafe-inline` style attributes added in changed files
- **AGENTS.md deploy**: ✅
  - No changes to AGENTS.md (git diff shows 0 lines)
  - No `scp` of D binaries — all engine changes go through BuildKit

## Issues

- **MINOR**: `idleEvents.enabled` flag is not checked as a runtime gate in the frontend processing path for temp_unavailable/idle events. Events flow through the existing `type: 'irc_event'` pipeline unconditionally. The flag exists, defaults OFF, and has a SettingsAdvanced toggle — it simply doesn't suppress event processing. Non-blocking because: (1) the engine still emits these regardless of the flag, (2) processing them is harmless (just sets store values), (3) BufferHeader UI is the only visible surface and it only renders when a temp_unavailable entry exists.
- **PRE-EXISTING**: 6 App.test.ts failures in "member list visibility on join/leave" tests (confirmed by git stash — present without Wave 1 changes). Not introduced by this wave.

## Test results

- **Lib suite**: 337/337 pass (16 files, all Wave 1 lib files: ignore.test.ts 20 ✓, utils.test.ts 93 ✓)
- **Client suite (Wave 1 files)**: 118/124 pass
  - App.test.ts: 24/30 pass (6 pre-existing failures)
  - InputArea.test.ts: 16/16 pass
  - BufferHeader.test.ts: 16/16 pass
  - ircStore.svelte.test.ts: 62/62 pass
- **New test coverage**: +1,164 lines of tests across 7 test files
- **Pre-existing failures**: 6 tests in App.test.ts (member list visibility on join/leave — confirmed unrelated)

## Decision
**PROCEED TO W1-T10 (CRITIC) + W1-T12 (DOCS)**

No blocking issues found. All 8 tasks meet acceptance criteria. Feature flags default OFF. Wire format is backward-compatible (type discriminator, silent fallthrough). CSP unchanged. No new test regressions. Pre-existing failures tracked separately.
