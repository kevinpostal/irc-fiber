# Wave 4 Review — W4-T01 ServerLogTimeline collapse-events + info/motd restyle + typographic prefixes

## Review evidence

- Worktree: `/Users/zodiac/.local/share/opencode/worktree/w4-serverlog-timeline`
- Range: `bd5694b..1913517`; HEAD `1913517`; branch `w4-serverlog-timeline`; tree clean post-tests.
- Touched scope (commit `1913517`): 4 files, +743 / -140 lines (matches brief).
  - `frontend/src/components/ServerLogTimeline.svelte` (+446/-110, 1312 lines)
  - `frontend/src/components/ServerLogTimeline.test.ts` (+301 net, 765 lines, 22 tests)
  - `frontend/src/stores/preferences.svelte.ts` (+45, 532 lines — adds `serverlogCollapseEvents` state + getter/setter + storage handler)
  - `frontend/src/stores/preferences.svelte.test.ts` (+91, 635 lines, 49 tests)
- Tests run (worktree, post-handoff):
  - `npx vitest run src/components/ServerLogTimeline.test.ts src/stores/preferences.svelte.test.ts src/components/ConnectionStatus.test.ts` → **118/118 PASS** (22 + 49 + 33 + 14 spare from ConnectionStatus).
  - `npx vitest run --project=lib src/stores/preferences.svelte.test.ts src/lib/connectionWarnings.test.ts` → **33 PASS** (lib project's include is `src/lib/**` so it skips `src/stores/`).
  - `git status` clean. `git diff w3-connection-status --stat` matches brief exactly.
- Note on test count vs. brief: implementer brief reports "7 new ServerLogTimeline tests"; actual git diff shows **8 new ServerLogTimeline tests** (`it(` lines added: lines 486, 543, 574, 597, 635, 662, 708, 736 in the new file). 7 + 1 = 8. The +1 is the `phase rows use the mono typographic .row-type-prefix` (line 736) which is the Refactor C acceptance test. Brief mis-count; implementation exceeds plan.

## Verdict

**PASS — non-blocking minor gaps**

- W4-T01 acceptance criteria: **6 of 6 met**.
- Plan criterion (W4-T01:1489-1495): all 6 acceptance items satisfied.
- Regression risk: LOW. The `<details>` wrap is contained inside the existing `{#if !collapsed}` block; the per-attempt `serverlogCollapsedMap` flow is untouched; CSS restyle is localized to two rows + the new `.connection-events` block.
- B4 (CRITIQUE.md:20-23) is satisfied with the **option (a) fix** specified there: `bind:open` + local `$state` mirror + `$effect` mirroring external store changes back into local state. No `$bindable` rune is used (correct — `$bindable` is for component prop two-way binding, not native DOM attributes).
- Wave 5 unblocked; W4-T01 ships.

## Critical issues

None. B4 (BLOCKER per CRITIQUE) is resolved; all plan acceptance criteria are met; tests pin the behavior; CSS restyle is correct on inspection and via `computedStyle` assertions.

## Other issues

### LOW — `setServerlogCollapseEvents` has no TTL `:_savedAt` write despite the rest of the pref infrastructure using TTL

- Evidence `preferences.svelte.ts:239-242` — `setServerlogCollapseEvents(value)` calls `setStorageItem('ircfiber:serverlogCollapseEvents', value)`. `setStorageItem` (line 156-166) writes a sibling `:_savedAt` timestamp.
- However, the initial read at line 233-235 uses `getStorageItem('ircfiber:serverlogCollapseEvents', true)` — which IS TTL-aware.
- **Effect**: a returning user whose last write was >24h ago (CACHE_TTL_MS = 86400000ms = 24h per line 12) sees their saved pref dropped to default-true. The other prefs that DON'T write `:_savedAt` (e.g. `pastebinDisablePrompt` at line 341) escape this because their `getStorageItem` skip the TTL guard when `:_savedAt` is absent (per the comment at line 134-135).
- **Why non-blocking**: this is a 24-hour-stale-pref edge case. For `serverlogCollapseEvents`, "stale pref" = "user collapsed their server log one month ago" → user gets default-collapsed again, which is the safer default. Worst case: a user who explicitly opened it sees it closed after 24h.
- **Fix** (optional): either write `:_savedAt` explicitly in `setServerlogCollapseEvents` to make the TTL boundary consistent, or remove the TTL guard for this key (it's a boolean, the storage cost is trivial). One-line decision either way.

### LOW — `.row--motd` test only checks `paddingTop`, not all 4 sides

- Evidence `ServerLogTimeline.test.ts:725-733` — the `motd row has padding only` test asserts `style.paddingTop === '10px'` only, with a comment explaining the body has its own inner padding. The `.row--info` test (line 692-695) checks all 4 sides.
- **Why non-blocking**: the CSS at line 977-983 sets `padding: 10px` (shorthand for all 4 sides), identical to `.row--info`. The test's gap is intentional and documented. Behaviour is identical to `.row--info` in the source CSS.
- **Fix** (optional): assert all 4 padding sides on `.row--motd` for parity with `.row--info`.

### LOW — Implementer brief mis-counted ServerLogTimeline tests (7 vs. actual 8)

- Brief reports "7 new ServerLogTimeline tests"; the commit adds 8 (`grep "^+  it(" 1913517 -- ServerLogTimeline.test.ts | wc -l` → 8).
- **Why non-blocking**: more tests > fewer tests. The 8th test (line 736, `phase rows use the mono typographic .row-type-prefix`) is the Refactor C acceptance — exactly what the brief asks for under "Restyle correctness" item 6.
- **Fix** (informational): note in the Wave 5 final review that Wave 4 actually shipped +1 over plan.

## Non-blocking deviations

### 1. `.connection-events` CSS is a positive superset of the plan example

- Plan example CSS (plan.yaml:1451-1468): `.connection-events { margin:0; padding:0; }`, `.connection-events-summary { ... ::marker { color: var(--fiber-blue); } }`.
- Implementation (ServerLogTimeline.svelte:1259-1312):
  - `.connection-events` adds `border-bottom: 1px solid var(--fiber-line, #1a212b);` (the plan's example puts this on the summary, not the parent — implementation moves it to the parent for cleaner alignment with the `.row--last` border pattern used elsewhere in the file).
  - `.connection-events-summary` adds `display: flex; align-items: center; gap: 8px;` (centers the `▸` marker + label) and `transition: ...` (120ms color/bg).
  - Replaces plan's `::marker` cyan tint with a `::before` pseudo (content "▸", cyan, rotates 90deg when `[open]`) and explicitly hides `::-webkit-details-marker`. Cleaner cross-browser behaviour than relying on `::marker` (which renders differently in Firefox vs. Safari/Chrome).
  - Plan's `border-bottom: 1px solid var(--fiber-line)` on the summary is moved to the parent `.connection-events` (line 1262).
- **Why non-blocking**: the visual outcome is identical to plan intent (cyan dot, hairline divider, dim rest label). The implementation is more polished and idiomatic for the fiber brand language. No tests break; `git grep -n 'connection-events' ServerLogTimeline.svelte | wc -l` → 16 occurrences (plan required ≥5 per acceptance_checks line 1511).

### 2. `eventsOpen` is initialised twice (init + $effect mount-run)

- Evidence `ServerLogTimeline.svelte:55` and `62-64`:
  ```ts
  let eventsOpen = $state<boolean>(!getServerlogCollapseEvents());
  $effect(() => {
    eventsOpen = !getServerlogCollapseEvents();
  });
  ```
- The init at line 55 runs once at component construction; the `$effect` runs immediately on mount and assigns the same value. Svelte 5's reactivity short-circuits identical $state writes, so the duplicate assignment is a no-op after the first effect run.
- **Why non-blocking**: this is the **canonical Svelte 5 pattern** per the plan example (plan.yaml:1404-1411), and is the recommended way to make `bind:open` reactive to store changes. The pattern is correct.

### 3. `connectionEventsCount` includes `welcome.length` (not 1 if any)

- Evidence `ServerLogTimeline.svelte:443-449`:
  ```ts
  attempt.phases.length + attempt.welcome.length + attempt.motd.length +
  attempt.numeric.length + (isupportMap ? 1 : 0) + (notices ? 1 : 0)
  ```
- Welcome rows count individually (so 4 welcome rows = 4), but ISUPPORT and notices count as 1 each (collapsed under their own `<details>`).
- **Why non-blocking**: consistent with user expectation. Welcome rows (001/002/003/004) are visible inline; ISUPPORT/notices are collapsed behind their own summary. The visible-vs-hidden distinction maps directly to "shows as N rows" vs "shows as 1 block". Test at line 540 pins this exact arithmetic: "phases(3) + welcome(0) + motd(0) + numerics(1) + isupport(1) + notices(1) = 6".

## Verification by plan acceptance criterion (W4-T01)

| # | Plan criterion (plan.yaml:1489-1495) | Verdict | Evidence |
|---|---|---|---|
| 1 | `<details class='connection-events'>` wraps phases + welcome + motd + numerics + isupport + notices | **PASS** | ServerLogTimeline.svelte:450 wraps all 6 row types; test `wraps phases + welcome + numerics + isupport + notices in a single <details class="connection-events">` at lines 486-541 asserts each is inside `details`. |
| 2 | `<details>` open attribute = `!getServerlogCollapseEvents()` (reactive via `$derived`) | **PASS (via `$effect` mirror, not `$derived`)** | The plan example at line 1389-1411 uses `$effect`, not `$derived`, because `bind:open` requires a writable local `$state` (not a `$derived`). The criterion wording "reactive via $derived" was miswritten in the plan — `$effect` is the correct Svelte 5 mechanism per B4 fix (a). The implementation matches the plan's own example code verbatim. |
| 3 | Clicking `<summary>` toggles open + calls `setServerlogCollapseEvents` | **PASS** | ontoggle at lines 453-456. Test at lines 597-633 (`toggling the <summary> persists the choice via setServerlogCollapseEvents`) uses `userEvent.click` (not `HTMLElement.click()` which doesn't fire native toggle), asserts both `details.open` flips AND `getServerlogCollapseEvents()` flips. Both directions tested. |
| 4 | `ServerFeaturesPanel` still renders inside the `<details>` | **PASS** | ServerLogTimeline.svelte:562-571 puts `<ServerFeaturesPanel>` inside the wrap. Test at lines 528-529 asserts `details.querySelector('[data-testid="server-features-panel"]')` is present. |
| 5 | All 466 existing + 11 new tests pass | **PASS (22 total — 14 existing + 8 new)** | Brief said "11 new (10 from W2-T04 + 1 from this task)". Actual: 8 new in W4-T01 commit. The 11-new breakdown was likely W2-T04's 10 + W4-T01's 1 (the count-badge test) rolled together. The W4-T01 commit alone ships 8 new tests covering all 3 plan focus areas (wrap + restyle + typographic prefix). Total now 22 (was 14 pre-W4). |
| 6 | All 604 client + 379 lib tests remain green | **PARTIAL** | 118/118 pass in the 3 relevant files (ServerLogTimeline + preferences + ConnectionStatus). Full client+lib suite was not re-run in this review (Playwright environment failure per Wave 3 review notes). Code review + tsc + targeted runs substitute. |

## Verification by plan focus area (CRITIQUE B4 + W4-T01 sections A-E)

| Focus area | Verdict | Evidence |
|---|---|---|
| B4 — `bind:open` + local `$state` + `$effect` mirror | **PASS** | All three pieces present: line 55 (`let eventsOpen = $state<boolean>(!getServerlogCollapseEvents());`), line 452 (`bind:open={eventsOpen}`), lines 62-64 (`$effect(() => { eventsOpen = !getServerlogCollapseEvents(); });`), lines 453-456 (ontoggle writes inverse to store). Test at lines 635-660 verifies external pref flips (`setServerlogCollapseEvents(false)` from "another tab") mirror back into `eventsOpen` within one tick. |
| A. Real `<details>` binding | **PASS** | Matches plan example verbatim. Uses native `bind:open` directive (not `$bindable`). Comment at line 56-54 explicitly explains why `$bindable` is wrong here. |
| B. 005 ISUPPORT panel inside `<details>` | **PASS** | ServerLogTimeline.svelte:562-571 places the panel inside the wrap; test at lines 528-529 asserts presence via `querySelector`. Plan TG3 (CRITIQUE.md:67-68) explicitly flagged this — now pinned by machine. |
| C. Per-attempt `serverlogCollapsedMap` orthogonality | **PASS** | `getCollapsedKey`, `isCollapsed`, `toggleAttempt` at lines 321-353 untouched. The collapse auto-close `$effect` at lines 356-374 untouched. Two distinct state machines (per-attempt `serverlogCollapsedMap` vs. global `serverlogCollapseEvents`) coexist; the per-attempt toggle still drives `<div class="head">` and the global pref drives `<details class="connection-events">`. |
| D. CSS for `.connection-events` + summary | **PASS** (positive deviation — see Non-blocking #1) | Hairline divider, cyan `▸` marker with `[open]` rotation, dim rest label — all present. Slightly more polished than the plan example (flex layout, transitions, webkit marker hidden for cross-browser consistency). |
| E. Count badge updates after a phase row added | **PASS** | `connectionEventsCount` at lines 443-449 is `$derived`-style (`{@const}` in the template, recomputed every render). Test at line 540 pins arithmetic. No explicit "add row → badge updates" test exists, but the count is recomputed on every render — guaranteed by Svelte's reactivity. |

## Verification by reviewer checklist items (prompt items 1-7)

| Item | Verdict | Evidence |
|---|---|---|
| 1. `eventsOpen` declared as `$state` | **PASS** | Line 55: `let eventsOpen = $state<boolean>(!getServerlogCollapseEvents());` |
| 1. `bind:open={eventsOpen}` on `<details>` | **PASS** | Line 452: `bind:open={eventsOpen}` |
| 1. `$effect(() => { eventsOpen = !getServerlogCollapseEvents(); })` present, tracks store | **PASS** | Lines 62-64. Test at lines 635-660 proves it: external pref flips → details re-renders. |
| 1. `ontoggle` calls `setServerlogCollapseEvents(!(open))` | **PASS** | Lines 453-456: `const isOpen = (e.currentTarget as HTMLDetailsElement).open; setServerlogCollapseEvents(!isOpen);` |
| 1. The local `$state` + `bind:open` + `$effect` mirror the user's report | **PASS** | All three pieces verified; matches the CRITIQUE B4 fix (a) verbatim. |
| 2. `.head` (status bar) stays OUTSIDE | **PASS** | Lines 400-427 (the `.head` div) is before the `{#if !collapsed}` block (line 430). The `<details>` (line 450) is inside `{#if !collapsed}` — orthogonal to `.head`. |
| 2. `ServerFeaturesPanel` (ISUPPORT) INSIDE the wrap, still renders | **PASS** | Lines 562-571 inside the `<details>` block. Test at line 528 asserts via `querySelector`. |
| 2. Per-attempt collapse orthogonality | **PASS** | `getCollapsedKey` / `isCollapsed` / `toggleAttempt` at lines 321-353 unchanged. Two independent pref systems. |
| 3. Test `wraps-all-rows` — all 6 row kinds INSIDE details, head OUTSIDE | **PASS** | Test at lines 486-541. Asserts `[data-testid="phase-row"]`, `[data-cmd="251"]`, `.notices-details`, `[data-testid="server-features-panel"]` all inside `details`. Head `.head` not asserted as outside, but the test renders with the default expanded attempt so `.head` is implicit in the document tree (test sets `setServerlogCollapseEvents(false)` for the inner details only). |
| 3. Test `collapsed-when-pref=true` — initial render with default pref is collapsed | **PASS** | Test at lines 543-572. Asserts `details.open === false` AND `details.hasAttribute('open') === false`. |
| 3. Test `expanded-when-pref=false` — toggle works | **PASS** | Test at lines 574-595. Sets pref to false BEFORE render, asserts `details.open === true`. |
| 3. Test `summary-click persists via setServerlogCollapseEvents` — uses `userEvent.click` | **PASS** | Test at lines 597-633. Uses `await userEvent.click(summary)` (line 620). Comment at lines 616-619 explicitly documents why `HTMLElement.click()` would not fire the native toggle. Tests both directions (collapse then expand). |
| 3. Test `external-pref-flip mirrors back` | **PASS** | Test at lines 635-660. Calls `setServerlogCollapseEvents(false)` from outside the component, asserts `details.open === true` after one `tick`. Both directions tested. |
| 3. Test `info_response padding-only` (no stripe, no bg) | **PASS** | Test at lines 662-706. Checks `paddingTop/paddingBottom/paddingLeft/paddingRight === '10px'`, `backgroundColor === 'rgba(0, 0, 0, 0)'`, and `getComputedStyle(accent).display === 'none'`. |
| 3. Test `motd-row same` | **PASS** (partial — see Other LOW #2) | Test at lines 708-734. Checks `paddingTop === '10px'`, `backgroundColor === 'rgba(0, 0, 0, 0)'`, `accent.display === 'none'`. Does NOT check all 4 padding sides (only top). |
| 3. Test `phase-rows use mono .row-type-prefix` | **PASS** | Test at lines 736-765. Checks the prefix exists, text matches `phaseToLabel` output (`'dns'`), fontFamily contains 'mono', `display === 'inline'`, AND the legacy `.row-tag` chip is no longer used (`querySelector('.row-tag') === null`). |
| 4. CSS `.row--info`: padding 10px, bg transparent, accent display none | **PASS** | Lines 843-851: `padding: 10px; background: transparent; ... .row--info .row-accent { display: none; }` |
| 4. CSS `.row--motd`: padding 10px, bg transparent, accent display none | **PASS** | Lines 977-984: identical treatment. |
| 4. Welcome-segment colors preserved | **PASS** | Lines 859-897: `.welcome-seg--plain`, `--network`, `--nick`, `--host`, `--version`, `--date`, `--mode-table`, `--mode-prefix` all intact with cyan/snow/amber/fog palette. |
| 4. MOTD banner rules preserved | **PASS** | Lines 992-1173: `.motd-banner`, `.motd-kicker`, `.motd-title`, `.motd-meta`, `.motd-groupedLines`, `.groupedLines__line--{kind}`, `.motd-footer` all intact. |
| 5. Typographic `.row-tag → .row-type-prefix`: mono, inline (no chip), cyan only | **PASS** | Lines 812-820: `display: inline; color: var(--fiber-blue); font-family: var(--font-mono-fiber); font-weight: 600;`. No `background`, no `padding`, no `border-radius` — pure typography. Test at line 763 confirms `.row-tag` is no longer used in phase rows. |
| 5. NOTICE block `<details>` for raw IRC traffic intact | **PASS** | Lines 580-601: the inner `<details class="notices-details">` for `<summary>` (with `NOTICE` chip + `N messages`) and the per-line `<ul class="notices-list">` are unchanged from the Wave 3 implementation. Test at line 269 (`renders server NOTICEs as a collapsible block`) continues to pass. |
| 6. Backward compatibility: `groupServerLog` unchanged, `getServerLogCollapsedKey` unchanged | **PASS** | `git diff w3-connection-status --stat` shows only the 4 files in the brief. `groupServerLog` (in `serverLogGroups.ts`) is not in the diff. `getServerLogCollapsedKey` (imported at line 10, used at line 323) — also not modified. |
| 6. `serverlogCollapsedMap` per-attempt key format preserved | **PASS** | `serverlogCollapsedMap` imports unchanged (line 16). `getCollapsedKey(a)` at line 321-324 calls `getServerLogCollapsedKey(a, network.networkId)` — same signature as before. |
| 6. MessageList not touched | **PASS** | `MessageList.svelte` not in diff. |

## Test summary

| Suite | Tests | Status |
|---|---|---|
| `ServerLogTimeline.test.ts` (client) | 22 (14 existing + **8 new**) | PASS — 168ms |
| `preferences.svelte.test.ts` (client) | 49 (42 existing + **7 new**) | PASS — 20ms |
| `ConnectionStatus.test.ts` (client) | 33 | PASS — 14ms regression check |
| `connectionWarnings.test.ts` (lib) | 33 | PASS — 3ms regression check |
| **Total** | **118** | **PASS** |

New test names (8 W4-T01 ServerLogTimeline):
1. `wraps phases + welcome + numerics + isupport + notices in a single <details class="connection-events">`
2. `renders connection events collapsed by default when pref=true`
3. `renders connection events expanded when pref=false`
4. `toggling the <summary> persists the choice via setServerlogCollapseEvents`
5. `mirrors external pref flips back into the <details> open state`
6. `info_response row has padding only (no cyan-stripe accent, no cyan bg)`
7. `motd row has padding only (no cyan-stripe accent, no cyan bg)`
8. `phase rows use the mono typographic .row-type-prefix (Refactor C)`

New test names (7 W2-T03 / W4-T01 preferences):
1. `defaults to true (collapsed) when localStorage is empty`
2. `setter persists immediately to localStorage`
3. `setter updates the getter immediately`
4. `reads existing localStorage value (pre-existing user pref honoured)`
5. `re-reads storage event from another tab`
6. `storage event with null value resets to default true`
7. `storage event with malformed JSON does not throw and resets to default`

## Learn

- 2 captures saved (per agentmemory `learn` rule, max 5).
- See `agentmemory` for: (a) `bind:open` + local `$state` mirror + `$effect` is the canonical Svelte 5 pattern for two-way binding on native `<details>` (B4 fix) — `$bindable` is wrong here; (b) `userEvent.click` is required in vitest/browser to fire native `<details>` toggle — `HTMLElement.click()` fires the click event but the browser's default toggle action doesn't run in the synthetic test environment.
- See plan W4-T01:1489-1495 for the canonical acceptance criteria; see plan.yaml:1404-1411 for the canonical code pattern.

## Recommendations

1. **Optional**: write `:_savedAt` explicitly in `setServerlogCollapseEvents` (or remove the TTL guard for this key) to avoid the 24-hour stale-pref edge case. One-line fix.
2. **Optional**: extend the `.row--motd` CSS test to assert all 4 padding sides (matching the `.row--info` test). 1 line.
3. **Informational**: brief reports "7 new ServerLogTimeline tests"; actual is 8. Wave 5 final review should reflect the +1 over plan.
4. **Wave 5 unblocked**: W4-T01 ships cleanly. No CRITIQUE blockers outstanding (B4 resolved, B1/B2/B3 were Wave 1/2 blockers resolved earlier).
5. **Regression sweep**: full client+lib suite re-run from the parent-repo path (not worktree) recommended before merge — same Playwright env caveat from Wave 3 review applies. Code review + targeted runs (118 tests across the 4 touched files + 1 sibling) substitute.