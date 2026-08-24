# 2026-06-27-irccloud-design-parity — Plan Summary

**Complexity:** HIGH
**Total tasks:** 64 (across 7 waves: Wave 0 prep + Wave 1..5 with Wave 4 split into 4a + 4b)
**Improvement items:** 34 (5 already_matched still listed for traceability)
**Pre-mortem scenarios:** 11 (added PM7-PM11 per critic) + 1 M2 conversationCollapsed path = 12 total
**Deploy target:** OVH `ircfiber-ovh-1` (x86_64) per AGENTS.md deploy architecture
**Critic verdict:** APPROVED_WITH_CHANGES (integrated 1 BLOCKING + 4 MAJOR + 6 MINOR + 5 pre-mortems)

## Wave Structure

| Wave | Theme | Tasks | Items | Reviewer | Critic | Deploy |
|------|-------|-------|-------|----------|--------|--------|
| 0 | Prep (feature flags) | 4 | 1 prep | W0-REV (full) | — | W0-DEPLOY (assets) |
| 1 | Foundation (engine protocol + schema) | 13 | 8 R# | W1-REV (full) | W1-CRIT | W1-DEPLOY (TWO-PHASE) |
| 2 | Cross-device sync | 7 | 3 R# | W2-REV (full) | — | W2-DEPLOY |
| 3 | Power-user UX | 10 (+1 engine) | 5 R#/D# | W3-REV (full) | — | W3-DEPLOY |
| 4a | Visual states + dividers | 13 (8 items + 5 meta) | 8 D# | W4a-REV (full) | W4a-CRIT | W4a-DEPLOY |
| 4b | Themes + remaining visual | 8 (5 items + 3 meta) | 5 D# | W4b-REV (full) | — | W4b-DEPLOY |
| 5 | Resilience | 9 | 5 R# | W5-REV (full) | — | W5-DEPLOY |
| **Total** | | **64** | **34** | | | |

## User Decisions (Q1-Q5, all resolved)

| Q | Task | Decision |
|---|---|---|
| Q1 | W1-T03 heartbeat_echo | New top-level WS type `{type:'heartbeat_echo', cid, bid[], ts}` — NOT overload `irc_event`. Batched per network (one frame per 30s with `bid[]` array). |
| Q2 | W1-T02 prefVersion | Inlined JSON field (`UserPreferences.prefVersion: long`). Atomic increment+save via Redis MULTI/EXEC. prefVersion resolves engine-vs-client but NOT tab-vs-tab (already handled by localStorage events). |
| Q3 | W1-T05 buffersToDelete | Always-on per WS reconnect (NOT per IRC reconnect). Client-side guard: `(bid NOT in activeJoinList)` before deletion. |
| Q4 | W1-T08 temp_unavailable | Render in BufferHeader (per-buffer). Engine emits `idle:since` per NETWORK (one timer per connection). Client countdown anchored on `serverTs + remaining_ms`. |
| Q5 | W3-T01 Cmd+K | Cross-network with disambiguation badge showing `serverName`. Single bulk `/api/buffers/archive-names` endpoint (W3-T01a engine task). Component takes `scope: 'all' \| 'active'` prop. |

## Critic Findings Addressed

### BLOCKING — C1 (R#6 Ignore migration)

Original plan heuristic (`NOT contains('!') OR '@'`) was broken for wildcard bare-nick patterns like `evil*`.
**Fix:** Heuristic is now `NOT (pattern.includes('!') || pattern.includes('@')) AND NOT (pattern.includes('*') || pattern.includes('?'))`. Only PURE bare-nick patterns are upgraded to `*!*@*`; patterns with any separator OR wildcard are preserved as-is in the IRCCloud 3-level map (host='*', user='*', nick=literal). Documented in `docs/IGNORE_MIGRATION.md` (created by W1-T07). Console-logs original pattern before transformation for audit.

### MAJOR — M1 (CSP claim)

Original plan claimed "CSP at `source/ircfiber/web/package.d` does not permit unsafe-inline".
**Fix:** CSP is actually at `deploy/roles/caddy/templates/Caddyfile.j2:61`. Current CSP permits BOTH `style-src 'unsafe-inline'` AND `script-src 'unsafe-inline' 'unsafe-eval'`. Wave 4 theming uses CSS variables as a BEST PRACTICE for maintainability, not because CSP forbids it. The existing `script-src 'unsafe-inline'` is flagged as a separate security item to track for future tightening.

### MAJOR — M2 (W1-T01 incomplete)

Original plan only fixed handlePrefUpdate path.
**Fix:** W1-T01 now adds `conversationsCollapsed` case to BOTH handlePrefUpdate (App.svelte:737-837) AND mergePreferences (App.svelte:630-735), mirroring the `inactiveCollapsed` pattern at App.svelte:690-699. Both paths tested in W1-T13.

### MAJOR — M3 (W3-T01 missing deps)

Original plan referenced `/api/buffers/archive-names` with no engine task.
**Fix:** Added W3-T01a (engine-side bulk endpoint with Mongo query + Redis cache TTL + PART invalidation). W3-T01 dependencies now include W1-T05 (safeChanSuffix for display name), W1-T06 (buffersToDelete wire), and W3-T01a (archive-names bulk endpoint).

### MAJOR — M4 (W5-T03 Linux escape)

Original plan: "escape via DOMParser".
**Fix:** REUSE existing `escapeHtml` from `frontend/src/lib/utils.ts:4` (already tested at `frontend/src/lib/utils.test.ts:19-46`). Matches IRCCloud's `escapeHtmlMinimal` behavior (escapes `&`, `<`, `>`, `"` — does NOT escape single quote). No new escape logic.

### MINOR — m1-m6 + Pre-mortems PM7-PM11

- **m1:** Feature-flag plumbing — W0-T01 creates `featureFlags` namespace in GlobalPrefs with 5 boolean flags
- **m2:** W1-T13 test path fixed to flat `frontend/src/lib/heartbeat.test.ts` (AGENTS.md convention, no `__tests__/`)
- **m3:** Wave 4 split into 4a + 4b (8 + 5 items)
- **m4:** W4b-T03 keeps `#app.midnight-theme` as backward-compat alias for new `body.theme-*` family
- **m5:** W5-T05 storage = Redis hash `member-activity:<networkId>:<nick>` with 30s debounce + 60s delta skip
- **m6:** Subsumed by M3 (W3-T01a created)

**Pre-mortems added:**
- **PM7:** Wave 1 deploy order (frontend first, wait 10 min, then engine) — two-phase deploy
- **PM8:** W5 XHR/WS lifecycle (explicit "WS primary, XHR shadow"; close XHR on WS success)
- **PM9:** W4 midnight-theme backward-compat (keep `#app.midnight-theme` selector, test in W4a-T13)
- **PM10:** W3 archive-names server RAM cost (5-minute client cache TTL)
- **PM11:** W5 lastSpoke Mongo hot-write (Redis hash + 30s debounce + 60s delta skip)

## Dependency Graph

```
W0-T01 ──► W0-T02 (REV) ──► W0-T03 (DEPLOY)
W0-T02 ──► W0-T04 (DOCS)

W0-T01 ──► W1-T02, W1-T03, W1-T04, W1-T06, W1-T08
W1-T01..T08 ──► W1-T09 (REV) ──► W1-T10 (CRIT) ──► W1-T11 (DEPLOY)  ← TWO-PHASE
W1-T09 ──► W1-T12 (DOCS)
W1-T01..T08 ──► W1-T13 (TESTS)

W1-T03 ──► W2-T01 (R#4b heartbeat UI)
W1-T01, W1-T02 ──► W2-T02 (R#19b pref fan-out verify)
W1-T02 ──► W2-T03 (R#11b prefVersion resolution)
W2-T01..T03 ──► W2-T04 (REV) ──► W2-T05 (DEPLOY)
W2-T04 ──► W2-T06 (DOCS)
W2-T01..T03 ──► W2-T07 (TESTS)

W1-T05 ──► W3-T01a (archive-names bulk endpoint)
W1-T05, W1-T06, W3-T01a ──► W3-T01 (R#1 Cmd+K switcher)
W3-T01..T05 ──► W3-T06 (REV) ──► W3-T07 (DEPLOY)
W3-T06 ──► W3-T08 (DOCS)
W3-T01..T04 ──► W3-T09 (TESTS)

W4a-T01..T08 ──► W4a-T09 (REV) ──► W4a-T10 (CRIT) ──► W4a-T11 (DEPLOY)
W4a-T09 ──► W4a-T12 (DOCS)
W4a-T01..T08 ──► W4a-T13 (VISUAL REGRESSION)

W4b-T01..T05 ──► W4b-T06 (REV) ──► W4b-T07 (DEPLOY)
W4b-T06 ──► W4b-T08 (DOCS)

W1-T03 ──► W5-T01 (R#9 XHR fallback)
W5-T01..T05 ──► W5-T06 (REV) ──► W5-T07 (DEPLOY)
W5-T06 ──► W5-T08 (DOCS)
W5-T01..T05 ──► W5-T09 (TESTS)
```

## High-Risk Signal Inventory

| Task | Signal | Mitigation |
|------|--------|------------|
| W1-T01 | `schema_change` (conversationsCollapsed in mergePreferences) | M2 fix: BOTH paths covered; explicit acceptance criteria |
| W1-T02 | `schema_change` (prefVersion field added to UserPreferences) | Atomic Redis MULTI/EXEC; feature flag `usePrefVersion` default OFF Wave 1 |
| W1-T03 | `wire_format_change` (heartbeat_echo new WS type, batched) | Feature flag `heartbeat.enabled` default OFF; batched per network (not per buffer) |
| W1-T04 | `capability_negotiation` (draft/edit-message IRCv3) | Feature flag `editMessage.enabled` default OFF; CAP check before sending |
| W1-T06 | `wire_format_change` (buffersToDelete always-on per WS reconnect) | Feature flag `buffersToDelete.enabled` default OFF; client-side activeJoinList guard |
| W1-T07 | `migration` (Ignore nick-only → `*!*@*` with C1 fix) | Heuristic checks separators AND wildcards; console-log original |
| W1-T05 | `low_risk` (safeChanSuffix parser) | No state mutation; pure parser addition |
| W1-T08 | `wire_format_change` (temp_unavailable, idle per NETWORK) | Feature flag `idleEvents.enabled` default OFF; BufferHeader countdown anchored on serverTs |
| W3-T01a | `wire_format_change` (archive-names bulk endpoint) | Redis cache with TTL; PART-event invalidation |
| W3-T01 | `cross_domain_impact` (ChannelSwitcher new component) | Q5: cross-network with serverName disambiguation; scope prop |
| W4a-T01..T08 | `cross_domain_impact` (SCSS partials touched) | Default theme = `dark` (no regression); `#app.midnight-theme` backward-compat |
| W4b-T03 | `theme_class_scope_change` (body.theme-* + #app.midnight-theme backward-compat) | PM9 mitigation: W4a-T13 visual regression test with saved `theme: 'midnight'` |
| W5-T01 | `wire_format_change` (XHR `?since=` long-poll) | PM8 mitigation: explicit "WS primary, XHR shadow" lifecycle; close XHR on WS success |
| W5-T03 | `security_sensitive` (Linux body escape) | M4 fix: reuse existing `escapeHtml`; matches IRCCloud escapeHtmlMinimal |
| W5-T05 | `schema_change` + `hot_write_path` (lastSpoke persistence) | PM11 mitigation: Redis hash + 30s debounce + 60s delta skip |

## Deploy Coordination (per Wave)

Each wave deploys via `make update` (Makefile:1299) or `make update-assets` (Makefile:1325) for frontend-only waves:

- **W0:** `make update-assets` (frontend only — feature flag plumbing)
- **W1:** **TWO-PHASE** — (1) `make update-assets` first; (2) wait ≥10 minutes for browser cache + load balancer refresh; (3) `make handoff` to deploy engine. Closes PM7 race.
- **W2:** `make update-assets` (frontend-only — feature flags flipped)
- **W3:** `make update-assets` (frontend-only — keyboard + dialog + new W3-T01a endpoint requires engine deploy)
- **W4a:** `make update-assets` (frontend-only — SCSS + Svelte)
- **W4b:** `make update-assets` (frontend-only — themes + remaining visual)
- **W5:** `make update` (engine + frontend; XHR + persistence)

**Hard rule per AGENTS.md:** Never `scp` D binaries (local ARM64 ≠ remote x86_64). All D builds via BuildKit on remote.

**CSP reality:** CSP at `deploy/roles/caddy/templates/Caddyfile.j2:61` currently permits `style-src 'unsafe-inline'` AND `script-src 'unsafe-inline' 'unsafe-eval'`. Wave 4 theming uses CSS variables as a BEST PRACTICE. The existing `script-src 'unsafe-inline'` is a tracked security concern for future tightening.

## Wave 5 Implementation Order (descending risk)

Per critic sequencing suggestion: T05 (lastSpoke persistence, schema_change) → T01 (XHR fallback) → T02 (OnlineChecker) → T03 (Linux escape, M4 fix reusing existing escapeHtml) → T04 (already matched verification). Implementer may execute in this order regardless of task ID sequence.

## Estimated Effort per Wave

| Wave | Person-days (loose) | Notes |
|------|---------------------|-------|
| 0 | XS (0.5-1 d) | Single prep task: feature-flag plumbing in GlobalPrefs |
| 1 | M (3-5 d) | 8 protocol items + tests + docs; cross-domain D ↔ Svelte split |
| 2 | S (2-3 d) | Mostly flag-flip + UI implementation; leverage Wave 1 scaffolding |
| 3 | M (3-4 d) | New dialog + hover toolbar + keyboard bindings + new engine endpoint (W3-T01a) |
| 4a | M (3-4 d) | 8 visual states + dividers; smaller scope than original Wave 4 |
| 4b | M (3-4 d) | 5 themes + custom CSS polish + midnight backward-compat |
| 5 | M (3-4 d) | 5 resilience features; XHR + persistence + notifications (use existing escapeHtml) |
| **Total** | **~18-24 pd** | |

## Already-Matched Items (no new work; listed for traceability)

| Item | Already in | Status |
|------|------------|--------|
| R#20 `/cycle + /quote slash commands` | `frontend/src/lib/slashCommands.ts:140,177` | already_matched |
| R#21 `inputHistory multiline gating` | `frontend/src/lib/inputHistory.ts:106-108` + `InputArea.svelte:189,202` | already_matched |

## Improvement Item Coverage (34 items)

| Wave | Item | Task | Status |
|------|------|------|--------|
| 1 | R#19 pref_update expansion | W1-T01 | pending (BOTH paths covered, M2 fix) |
| 1 | R#11 prefVersion schema | W1-T02 + W2-T03 | pending (MULTI/EXEC atomic) |
| 1 | R#4 heartbeat_echo wire | W1-T03 + W2-T01 | pending (batched per network) |
| 1 | R#2 edit-message binding | W1-T04 + W3-T03 | pending |
| 1 | R#5 buffersToDelete | W1-T06 | pending (activeJoinList guard) |
| 1 | R#6 Ignore.check 3-level | W1-T07 | pending (C1 heuristic fix) |
| 1 | R#13 safeChanSuffix IDCHAN | W1-T05 | pending (moved earlier) |
| 1 | R#10 temp_unavailable + idle | W1-T08 | pending (BufferHeader, per-NETWORK) |
| 2 | R#4b lastSeen UI | W2-T01 | pending |
| 2 | R#19b pref_update fan-out | W2-T02 | pending |
| 2 | R#11b prefVersion resolution | W2-T03 | pending |
| 3 | R#1 Cmd+K channel switcher | W3-T01 + W3-T01a | pending (cross-network + bulk endpoint) |
| 3 | D#2 per-row hover toolbar | W3-T02 | pending |
| 3 | R#2b Ctrl/Cmd+Up edit-last | W3-T03 | pending |
| 3 | R#15 Tab cycling modes | W3-T04 | pending |
| 3 | R#20 /cycle + /quote | W3-T05 | already_matched |
| 4a | D#1 themed row backgrounds | W4a-T01 | pending |
| 4a | D#3+D#14 member mode-prefix glyphs | W4a-T02 | pending |
| 4a | D#6 connection-status pill | W4a-T03 | pending |
| 4a | D#7 pending/failed states | W4a-T04 | pending |
| 4a | D#10 mobile 44×44 audit | W4a-T05 | pending |
| 4a | D#5 empty-channel hint | W4a-T06 | pending |
| 4a | D#9 typing-indicator bounce | W4a-T07 | pending |
| 4a | D#12 settings page dividers | W4a-T08 | pending |
| 4b | D#4 date-header gradient | W4b-T01 | pending |
| 4b | D#13 sidebar chevron color | W4b-T02 | pending |
| 4b | D#8 5+ theme palettes | W4b-T03 | pending (midnight backward-compat) |
| 4b | D#11 away indicator | W4b-T04 | pending |
| 4b | D#15 custom CSS editor | W4b-T05 | pending |
| 5 | R#9 WS→XHR fallback | W5-T01 | pending (WS primary, XHR shadow) |
| 5 | R#8 OnlineChecker + /ping | W5-T02 | pending |
| 5 | R#7 Notification notStore | W5-T03 | pending (reuse escapeHtml) |
| 5 | R#21 inputHistory multiline | W5-T04 | already_matched |
| 5 | R#24 Member lastSpoke merge | W5-T05 | pending (Redis hash + debounce) |

## Key File References

- Plan: `docs/plan/2026-06-27-irccloud-design-parity/plan.yaml`
- Context: `docs/plan/2026-06-27-irccloud-design-parity/context_envelope.json`
- Visual design audit: `docs/IRCCLOUD_VISUAL_DESIGN_AUDIT.md:1-632`
- Deploy targets: `Makefile:1299-1364`
- CSP location: `deploy/roles/caddy/templates/Caddyfile.j2:61` (NOT `source/ircfiber/web/package.d`)
- Existing escapeHtml: `frontend/src/lib/utils.ts:4` (reused by W5-T03)
- AGENTS.md: testing guide, deploy architecture, graceful hot-reload, connection-holder

## Reviewer-Gate Mechanics

- Each wave ends with `W{n}-REV` (gem-reviewer, `review_depth: full`).
- `W{n}-REV` BLOCKS `W{n}-DEPLOY` (gem-devops).
- `W1-CRIT` and `W4a-CRIT` run after reviewer gate; produce risk register for next wave.
- Each critic review targets high-complexity gates: `contract_change`, `breaking_change`, `schema_change`, `migration`, `cross_domain_impact`.
- Wave 4 split adds W4a-REV + W4a-CRIT + W4a-DEPLOY before W4b-REV + W4b-DEPLOY (reduces blast radius per wave).

## Cross-References to IRCCloud

| IRC Fiber Task | IRCCloud Source |
|----------------|-----------------|
| W1-T07 (Ignore) | `/Users/zodiac/Downloads/webpack:/app/src/ignore.js:1-160` |
| W5-T02 (OnlineChecker) | `/Users/zodiac/Downloads/webpack:/app/src/onlinechecker.js:1-76` |
| W5-T03 (Notification) | `/Users/zodiac/Downloads/webpack:/app/src/irccloudnotifier.js:1-152` |
| W5-T03 (escapeHtmlMinimal) | `/Users/zodiac/Downloads/webpack:/app/src/ircformatter.js:131-141` |
| W3-T01 (Cmd+K switcher) | `/Users/zodiac/Downloads/webpack:/app/src/view/channelswitchdialogview.js` + `channelswitchdialog.es6:154-238` |
| W3-T03 (Ctrl/Cmd+Up) | `/Users/zodiac/Downloads/webpack:/app/src/lib/keyboard.es6:1-68` |
| W5-T01 (XHR fallback) | `/Users/zodiac/Downloads/webpack:/app/src/xhrstreamhandler.js` |
| All Wave 4 visual items | `docs/IRCCLOUD_VISUAL_DESIGN_AUDIT.md` + `/Users/zodiac/Downloads/webpack:/app/src/common-ba9dfbf7.js` |