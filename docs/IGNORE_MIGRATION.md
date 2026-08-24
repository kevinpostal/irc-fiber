# Ignore System Migration: Regex → 3-level Map

## What changed

The `/ignore` system was upgraded from a simple regex-based check to a **full
3-level map** (`host → user → set<nick>`) ported from IRCCloud's `ignore.js`.

### Before (simple regex)
- `isIgnored(nick)` compiled each pattern into a RegExp on every call
- No host-based ignore support — only nick matching
- `*` and `?` treated as regex wildcards (`.*` and `.`)

### After (3-level map)
- `IgnoreMap` stores patterns at three levels: host, user, nick
- `IgnoreMap.check(nick, hostmask?)` walks `host → user → nick` with exact
  matches, IRC `*` wildcards, and catch-all `*` at each level
- Host-based ignores now work: `/ignore *!*@evil.host` ignores everyone from
  `evil.host`
- Performance: parsed once, checked in O(1) for exact matches

## Migration: what happens to existing patterns

A heuristic (`upgradeLegacyPattern`) runs on every pattern the first time the
map is built:

| Pattern type | Example | Upgrade? | Result |
|---|---|---|---|
| Pure bare nick (no `!`, `@`, `*`, `?`) | `bob` | Yes | `bob!*@*` |
| With separator | `alice!*@*` | No | Stored as-is |
| With wildcard | `evil*` | No | Stored as literal nick `evil*` |
| With `?` | `jane?` | No | Stored as literal nick `jane?` |

The upgrade converts bare-nick patterns (the common case from the old regex
system) into `nick!*@*` format, which the 3-level map interprets as "match this
nick regardless of user@host".

Patterns that already contain `!`, `@`, `*`, or `?` are preserved as-is — the
heuristic assumes they are intentional IRC masks.

### C1 fix: wildcard detection

The migration heuristic checks **both** separators AND wildcards before
deciding to upgrade. Without this, a user with `ignoreList = ['evil*']` would
have `evil*` (which the old regex treated as `evil.*` matching `eviltwin`,
`evilone`, etc.) become a bare nick `evil*` — silently losing the wildcard
behavior.

With the fix: if the pattern contains `*` or `?`, it is preserved as-is without
upgrading. The pattern is stored in the 3-level map as a **literal nick**
string — `evil*` matches only the exact nick `evil*`, not `eviltwin`.

## Console audit trail

Every pattern upgrade is logged to the browser console:

```
[Ignore] upgrading bare nick pattern: bob
[Ignore] upgrading bare nick pattern: alice
```

Patterns that are not upgraded are NOT logged, keeping noise minimal.

## File layout

- `frontend/src/lib/ignore.ts` — `IgnoreMap` class, `upgradeLegacyPattern()`,
  `parseIgnoreList()`
- `frontend/src/stores/preferences.svelte.ts` — `isIgnored()` now uses
  `IgnoreMap`, rebuilt via `$effect` on `ignoreList` change
- `frontend/src/lib/ignore.test.ts` — test suite (28+ tests)

## How to rollback

1. Open DevTools → Application → Local Storage → `ircfiber:ignores`
2. Edit any bare-nick patterns that were upgraded: remove `!*@*` suffix
3. The old `isIgnored` function can be restored by reverting
   `frontend/src/stores/preferences.svelte.ts` to the regex-based
   implementation

The original pattern is never modified in localStorage — only the in-memory
`IgnoreMap` receives the upgraded version. The stored `ignoreList` array always
contains the user's original patterns.
