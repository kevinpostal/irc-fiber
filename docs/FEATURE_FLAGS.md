# Feature Flags - Rollout Guide

## Overview

IRC Fiber uses a feature-flag system to ship Wave 1/2 IRCCloud-parity improvements behind opt-in toggles. Most flags default OFF for safe rollout; `usePrefVersion` flips ON in Wave 2. This document is the operator reference: which flag gates what, where flags live, and how to enable them.

User-facing narrative and ship notes live in `docs/CHANGELOG.md`. This file is the runbook.

## Flag reference

| Flag | Gates Wave 1 task | Default | When to enable |
|---|---|---|---|
| `usePrefVersion` | W2-T03 (prefVersion last-write-wins) | ON (W2) | ON by default in Wave 2; last-write-wins conflict resolution across devices |
| `heartbeat` | W1-T03 (heartbeat_echo wire) | OFF | After W1-T03 deploy + Wave 1 two-phase deploy completes |
| `editMessage` | W1-T04 (edit-message wire) | OFF | After W1-T04 deploy; IRCv3 `labeled-response` + `message-tags` caps required |
| `buffersToDelete` | W1-T06 (buffersToDelete wire) | OFF | After W1-T06 deploy; protects ghost channels after long disconnects |
| `idleEvents` | W1-T08 (temp_unavailable + idle events) | OFF | After W1-T08 deploy; shows server-side connection state in BufferHeader |

## Where flags live

- **Client-side:** `frontend/src/stores/preferences.svelte.ts` -> `globalPrefs.featureFlags.X`
- **Server-side:** `source/ircfiber/db/preferences.d` - `UserPreferences.prefVersion` added in W1-T02
- **UI controls:** Settings -> Advanced tab (`frontend/src/components/SettingsAdvanced.svelte`)

## How to enable a flag for a single user (testing)

1. Log in to https://ircfiber.com
2. Navigate to Settings -> Advanced
3. Toggle the desired flag ON
4. Reload the page (flag persists via localStorage)

For server-side flags (added in later waves), the admin API will be exposed at `/api/admin/users/:id/feature-flags`. Until then, server-side flags are scoped per-deploy.

## How to enable a flag globally (operator only)

Until the admin API ships (deferred), flag toggles are per-user. For production rollout:
1. Deploy the Wave 1 task that adds the flag
2. Verify the flag works in single-user testing (above)
3. Once stable, the Wave 1 task that consumes the flag will default to ON for everyone

## Cross-device sync gap (CURRENT LIMITATION)

`broadcastPrefUpdate` in `source/ircfiber/api/rest.d:988` currently fans out 8 specific keys (`pinned`, `archived`, `collapsed`, `conversationsCollapsed`, `inactiveCollapsed`, `serverlogCollapsed`, `membersCollapsed`, `networkOrder`, `bufferPrefs`) but does NOT include `featureFlags`.

This means: if you toggle `heartbeat` ON in your desktop browser, your mobile browser won't see the change until the Wave 1 task that consumes the flag also adds `'featureFlags'` to `broadcastPrefUpdate`. Tracked as a known limitation; will be addressed when each Wave 1 task ships.

For now: cross-tab sync (within one browser) works via localStorage `storage` event handler at `frontend/src/stores/preferences.svelte.ts:357-376`. Cross-device sync (mobile <-> desktop) requires per-device toggle.

## Safety

- `usePrefVersion` defaults ON in Wave 2; all other flags default OFF
- Toggling a flag without the corresponding backend feature shipping is a no-op (the frontend code reads the flag but the backend doesn't emit/sync the new wire format yet)
- Toggling a flag OFF mid-session reverts to the pre-Wave behavior immediately

## Testing checklist per flag

For each flag:
1. Enable in single-user test
2. Verify expected behavior matches the gating task's acceptance criteria
3. Disable; verify revert to baseline behavior
4. Test in second browser tab; verify cross-tab sync works
5. Test in second device; verify expected cross-device behavior (or document the gap if not yet wired)

## Related

- `docs/CHANGELOG.md` - Wave 0 release notes (commit `d47c00b`)
- `docs/plan/2026-06-27-irccloud-design-parity/plan.yaml` - Wave 1..5 task plan; flags gate Wave 1 deploy
