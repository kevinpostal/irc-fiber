# Changelog

All notable changes to IRC Fiber are documented here. Format follows [Keep a Changelog](https://keepachangelog.com/): newest first, grouped by Added / Changed / Fixed / Removed. Versions date-stamped; unreleased work lives under `[Unreleased]`.

## [Unreleased] - Wave 6 (IRCCloud-style rejoin feel)

### Added
- **W1-T01:** `initiateRejoin(networkId, bufferName, opts)` helper in `ircStore.svelte.ts` — single canonical entry point for all user-initiated JOIN attempts (BufferHeader Rejoin, ChannelContextMenu Rejoin, `/cycle|/hop|/rejoin` slash, `maybeAutoJoinChannel`). Sets the full state-machine quartet (`joinError=null`, `joinInFlight=true`, `pendingIsJoined=true`, `pendingConfirmations=2`) plus `markJoinPending`, `recordJoin`, `prePopulateOwnNick` (so the member panel includes the user within one tick), and sends `JOIN`. `opts.allowReconnect` flag preserves BufferHeader's disconnect-then-JOIN behavior; the other three paths pass `false` to avoid racing the connection-recovery paths.
- **W1-T01:** `prePopulateOwnNick` (colocated in `ircStore.svelte.ts`) — stripPrefix-safe dedup mirrors the 353 in-place promotion at `ircStore.svelte.ts:1696-1701`, so a later NAMES reply with a prefixed form (e.g. `@me`) does NOT create a duplicate entry.

### Changed
- **W1-T01:** `/cycle`, `/hop`, `/rejoin` slash commands now issue JOIN only (no PART-before-JOIN). Previous behavior was `sendRaw('PART <chan>')` followed by `sendRaw('JOIN <chan> + key')`; PART-before-JOIN clobbered `isJoined=true` mid-flow and broke the optimistic Joining chip. IRCCloud's `/cycle` semantics is "just rejoin" — matches that. Key extraction logic is preserved (the `key` variable is parsed but not currently sent to `initiateRejoin`; the helper does not accept a key today — a future enhancement can extend the helper's signature).
- **W1-T01:** `BufferHeader.rejoin()` body collapsed from a 22-line inline implementation to a single delegate call to `initiateRejoin(networkId, name, { allowReconnect: true })`.
- **W1-T01:** `ChannelContextMenu.rejoin()` body collapsed from a 3-line `sendRaw + onClose` stub to a delegate call to `initiateRejoin(networkId, name, { allowReconnect: false })`. Context-menu Rejoin now sets all four state-machine flags (was setting zero — primary bug fix; buffersToDelete during WS resume can no longer reap the buffer because `recordJoin` is now called).
- **W1-T01:** `App.svelte:maybeAutoJoinChannel` body collapsed to a single delegate call to `initiateRejoin(networkId, normalized, { allowReconnect: false })`. The early-return guards (non-channel buffer, already-joined, disconnected network, pendingJoins dedup) are preserved inline so `maybeAutoJoinChannel` retains its lightweight entry-point character.

## [Unreleased] - Wave 5 (Resilience)

### Added
- **W5-T01:** WS → XHR stream fallback — automatic long-poll fallback when WebSocket fails (corporate proxies, captive portals); "WS primary, XHR shadow" lifecycle with no-double-delivery via maxEidTracker
- **W5-T02:** OnlineChecker — HEAD /api/ping with 2s timeout + 30s poll; double-checks navigator.onLine to handle Chrome false negatives
- **W5-T03:** Notification notStore + tag-based dedup + Linux body escape — Safari GC protection, 10 repeats from same nick = 1 notification
- **W5-T05:** Member lastSpoke/lastHighlighted merge on reconnect — preserves tab completion sort across WS reconnects

## [Unreleased] - Wave 4b (Visual polish B)

### Added
- **W4b-T01:** Date-header gradient — CSS-variable-driven gradient (`--row-date-bg-from`/`--row-date-bg-to`) + text shadow; midnight theme overrides for backward compat
- **W4b-T02:** Sidebar chevron hover color `#b3cfff` + rotate animation on collapse
- **W4b-T03:** 5 new theme palettes — Dusk, Tropic, Emerald, Sand, Orchid; theme picker dropdown in SettingsDesign; 8 total themes
- **W4b-T04:** Away indicator — pulsing amber dot in input nickcell when `/away`, with `prefers-reduced-motion` fallback
- **W4b-T05:** Custom CSS editor polish — real-time CSS validation, success/error feedback, reset button

## [Unreleased] - Wave 4a (Visual polish A)

### Added
- **W4a-T03:** ConnectionStatus as themed pill banner (IRCCloud parity)
- **W4a-T05:** Interactive header chrome bumped to 44×44 on mobile
- **W4a-T06:** Empty-channel hint state for MessageList
- **W4a-T07:** Typing-indicator dot bounce animation with `prefers-reduced-motion` support
- **W4a-T08:** SettingsSection component for consistent section dividers

## [Unreleased] - Wave 1 (Foundation: Protocol & Engine)

Commits: `029bc0a..b7db06d` - 8 feature commits across engine + frontend.

### Added
- **W1-T01:** `conversationsCollapsed` pref handler in BOTH `handlePrefUpdate` (WS live) and `mergePreferences` (boot seed). Fixes pref reset on stat_user boot (M2 critic fix).
- **W1-T02:** `prefVersion` counter for engine-vs-client merge resolution.
  - `UserPreferences.prefVersion` field (D struct) incremented atomically on every `prefsRepo.save()` via Redis Lua EVAL
  - `stat_user` payload includes `prefVersion`; frontend `mergePreferences` uses last-write-wins (strict-greater comparison)
  - Does NOT resolve tab-vs-tab conflicts (handled by localStorage events)
  - Gated behind `usePrefVersion` feature flag
  - See `docs/PREF_VERSION.md` for full design
- **W1-T03:** `heartbeat_echo` wire protocol (new top-level WS type, batched per network with bid[] array)
  - Engine emits one heartbeat per network per 30s from shared timer
  - Frontend `handleHeartbeat` merges into `lastSeenMap`
  - Gated behind `heartbeat` feature flag
- **W1-T04:** IRCv3 `draft/edit-message` support
  - Ctrl/Cmd+Up in input area: edits last sent message with `[edit]` prefix
  - Engine `EditMsgOut` send path with capability negotiation
  - Label echo merges into existing message (no new row)
  - Gated behind `editMessage` feature flag
- **W1-T05:** `getDisplayName()` utility for safe channel prefix stripping (ISUPPORT PREFIX)
  - D parser extracts PREFIX symbols from ISUPPORT
  - Frontend utility strips leading mode-prefix chars from channel names
- **W1-T06:** `buffersToDelete` wire protocol for ghost channel cleanup
  - Engine emits once per WS reconnect with bid[] list
  - Frontend prunes guarded by activeJoinList + archived/pinned/hidden maps
  - Gated behind `buffersToDelete` feature flag
- **W1-T07:** Full 3-level IgnoreMap (nick -> user -> host) per IRCCloud `ignore.js`
  - Replaces simple regex-based `isIgnored` with 3-level map for O(1) performance + host-based ignores
  - Migration: only pure bare-nick patterns upgraded to `*!*@*`; patterns with `!`, `@`, `*`, `?` preserved as-is (C1 critic fix)
  - Console.log audit trail before any transformation
  - See `docs/IGNORE_MIGRATION.md` for full migration guide
- **W1-T08:** `temp_unavailable` + idle server signals
  - Engine recognizes RPL_TRYAGAIN (263) and emits synthetic events
  - BufferHeader renders countdown chip: "Server busy -- retry in {n}s"
  - Per-NETWORK idle timer (NOT per-channel)
  - Gated behind `idleEvents` feature flag

### Feature flags (all default OFF)
- `usePrefVersion` - gates prefVersion schema (W1-T02)
- `heartbeat` - gates heartbeat_echo wire (W1-T03)
- `editMessage` - gates edit-message binding (W1-T04)
- `buffersToDelete` - gates buffersToDelete wire (W1-T06)
- `idleEvents` - gates temp_unavailable + idle (W1-T08)

## [Unreleased] - Wave 2 (Cross-device sync)

### Added
- **W2-T01:** lastSeen heartbeat — frontend sends per-buffer read state to server every 10s (gated behind `heartbeat.enabled` flag)
- **W2-T02:** pref_update fan-out — all 9 pref keys (including conversationsCollapsed) now bridge engine ↔ frontend via D struct + stat_user + REST broadcast. Extra draining machinery bundled (non-critical scope drift).
- **W2-T03:** prefVersion resolution — `usePrefVersion` now defaults ON; mergePreferences uses last-write-wins for engine-vs-client sync

## [Unreleased] - Wave 0 (Foundation: Feature flags)

Commit: `d47c00b feat(W0-T01): add feature flag scaffolding for Wave 1 protocol changes` - 7 files, +370/-4.

### Added
- Feature flag scaffolding in `GlobalPrefs.featureFlags` namespace (`frontend/src/stores/preferences.svelte.ts`)
  - `usePrefVersion` - gates W1-T02 (prefVersion schema resolution)
  - `heartbeat` - gates W1-T03 (heartbeat_echo wire protocol)
  - `editMessage` - gates W1-T04 (edit-message binding)
  - `buffersToDelete` - gates W1-T06 (buffersToDelete wire protocol)
  - `idleEvents` - gates W1-T08 (temp_unavailable + idle events)
- `Settings -> Advanced` tab with toggle controls for each flag; all default OFF
  - `frontend/src/components/SettingsAdvanced.svelte` - 5 accessible switches (role=switch, aria-label, aria-checked)
- 9 new tests: 5 store tests (defaults, localStorage persistence, deep-merge, cross-tab sync) + 4 component tests (render, a11y, bind:checked round-trip) - all pass
- `FeatureFlag` / `FeatureFlags` interfaces + `mergeDefaults` deep-merge so partial saved data preserves nested `{ enabled: false }` defaults

### Changed
- `frontend/src/lib/routing.ts` - `SettingsTab` union extended with `'advanced'`; URL regex accepts `advanced` tab
- `frontend/src/stores/ircStore.svelte.ts` - `SettingsTab` type extended with `'advanced'`
- `frontend/src/components/SettingsPage.svelte` - adds Advanced tab button + render block

### Known limitations (tracked for future waves)
- **Cross-device sync gap:** `broadcastPrefUpdate` in `source/ircfiber/api/rest.d:988` does NOT yet include `featureFlags` key. localStorage cross-tab sync works (storage event handler at `frontend/src/stores/preferences.svelte.ts:357-376`); cross-device sync requires Wave 1 protocol changes to add `'featureFlags'` to the server pref blob fan-out. See `docs/FEATURE_FLAGS.md` for the rollout strategy.
