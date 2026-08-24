# Plan 20260716-irccloud-parity — final review summary

This is the index for all five wave reviews + the smoke
artefacts shipped under Wave 5. Each pointer is the full
review document; this file is a one-page summary of the
cross-wave verdict + outstanding work.

## Wave reviews

| Wave | Review | Verdict | Highlights |
|---|---|---|---|
| 1 | [review-wave1.md](./review-wave1.md) | NEEDS REVISION (rev1 → shipped clean) | `CONNECTION_RETRY_STATUS` + `CONNECTION_FAIL` factories + `FailInfo` nested shape + zero-clear emits at every `backoff.reset()` site. Rev1 fixed zero-delay, intentional-disconnect, casing, ordering |
| 2 | [review-wave2.md](./review-wave2.md) | PASS | `renderReasons` + `suspiciousConnection` helpers (consolidated into `connectionWarnings.ts` in Wave 3), `messageHandler` dispatch, `ircStore.applyRetryStatus/applyFail` plumbing, `serverlogCollapseEvents` pref. 498 lib tests + 772 client tests green |
| 3 | [review-wave3.md](./review-wave3.md) | NEEDS REVISION (rev1 → shipped clean) | 11-state `ConnectionStatus` banner, `connectionWarnings` consolidation, `vi.getTimerCount()` unmount-cleanup test. Rev1 added 6 missing transient states + E.LEGACY test + `focusOnMakeBuffer` + `ip_retry` |
| 4 | [review-wave4.md](./review-wave4.md) | PASS | `<details class="connection-events">` wrap (B4 `bind:open` + local `$state` + `$effect` mirror — NOT `$bindable`), typographic `.row-type-prefix` replacing the `.row-tag` cyan chip, padding-only `.row--info` / `.row--motd` (no cyan stripe, no cyan bg) |
| 5 | (this document) | PASS — non-blocking gaps | AGENTS.md section shipped; engine smoke documented at code-inspection level (live `dub run` deferred to deploy-time); visual smoke spec written (capture not blocking) |

## Smoke artefacts (W5-T02)

| File | Purpose | Status |
|---|---|---|
| [engine-smoke.md](./engine-smoke.md) | Three plan-section-G scenarios (closed-port retry, failInfo emission, failInfo clear-after-reconnect) — code-inspected + frontend-pinned. Live `dub run` deferred to deploy-time per worktree constraints | SPEC (code-pinned) |
| [visual-smoke.md](./visual-smoke.md) | Five browser scenarios (happy-path, retry countdown, events collapse, suspicious warnings, ISUPPORT inside wrap, welcome/MOTD restyle). Mapped to machine-test verifications | SPEC (not captured) |

## Cross-wave verdict

**PASS — non-blocking gaps.**

- All 5 user-stated acceptance bullets are machine-pinned by
  vitest cases (see W3 + W4 review tables).
- The wire contract (engine emit shape, WS sync payload,
  snapshot roundtrip, frontend apply-store) is consistent
  across waves 1 → 2 → 3 → 4. The Wave 2 review verified
  the byte-for-byte nested `sslVerifyError` shape (B2
  invariant); the Wave 3 review verified the engine-emit
  vs frontend-store alignment for the 11 BannerKind branches.
- The visual deliverable matches the IRCCloud visual grammar
  in spirit (collapsible connection events, hairline-bar
  banner, typographic welcome/MOTD, structured fail copy)
  while keeping the fiber palette (no new CSS tokens, no
  IRCCloud fonts).

## Outstanding work (out-of-scope for this plan, but flagged)

These items were called out as future work in the plan
brief and remain out of scope here:

1. **IRCCloud join/part grouping** — applies to channel
   buffers, not the server log; future surface area.
2. **`failed` / `failedMessage` pending-row styling** —
   applied to JOIN/MODE response rows in channel buffers;
   future surface area.
3. **Fiber brand font replacement** — already uses Space
   Grotesk for labels and fiber-mono for content; no change
   requested.
4. **`--fiber-amber-soft` palette token** — referenced by
   `.banner--fail` CSS but not yet defined in `homepage.yml`.
   Falls back transparently to `rgba()` if absent. Tracked
   as a 1-line palette follow-up.
5. **Engine `dub test` build** — pre-existing on `main`,
   unrelated to this work. `dub build --config=…` works.

## CRITIQUE item resolution status

| Item | Resolution |
|---|---|
| B1 (engine enum + retry site) | Resolved in `w1-t01-engine-retry-fail` rev1 (`connection.d:1717` enum + `:1745` state set + `:1914` transition back) |
| B2 (nested FailInfo) | Resolved — engine emits `Json(string[string])` for `sslVerifyError`; frontend matches byte-for-byte (`ircStore.svelte.test.ts:2985-2999`) |
| B3 (zero-clear at every reset) | Resolved in rev1 — three `backoff.reset()` sites all emit zero (`connection.d:1151-1158`, `:1307-1309`, `:1685-1690`); 4th site added in rev1 |
| B4 (`bind:open` + local `$state` + `$effect` mirror) | Resolved in `w4-serverlog-timeline` — `ServerLogTimeline.svelte:55, 452, 62-64` |
| OE5 (Wave-4 reviewer redundancy) | Resolved at plan time — `W4-T02` deleted; Wave 4 reviewed as part of Wave 5 |
| OE1 (renderReasons surface trim) | Resolved in `w2-frontend-helpers` — only `renderReason` + `renderSSLVerify` exported; test pins the surface |
| TG1 (renderReasons pins) | Resolved in `w2-frontend-helpers` — exhaustive table test at `renderReasons.test.ts:36-55` |
| TG2 (E.LEGACY fallback) | Resolved in `w3-connection-status` rev1 — added `disconnectReason`-only network test |
| TG5 (zero clear invariant) | Resolved in `w2-frontend-helpers` — `applyRetryStatus(null)` clears `retryStatus` AND `failInfo` (TG5 test at `ircStore.svelte.test.ts:2839-2868`) |
| R1 (reason-keyword mapping) | Resolved at implementation time — `parseReasonToFailInfo` helper at `connection.d:4120-4175` |
| R2 (failInfo vs disconnectReason) | Resolved implicitly via W3 banner branch + TG2 test (see review-wave3.md `Non-blocking deviations #2`) |
| R4 (UX-discovery call) | Out-of-scope; future enhancement |
| R5 (CSS fallback) | Resolved — `--fiber-amber-soft` falls back to `rgba()` when token absent |

## Worktree chain

The plan shipped as 5 sequential worktrees branching from
`b9b2f4e` (the `main` HEAD at plan start):

```
b9b2f4e (main)
├── w1-t01-engine-retry-fail      d047d8f (W1-T01 + W1-T01-rev1)
├── w2-frontend-helpers           d2fd53b (W2-T01..W2-T04)
├── w3-connection-status          bd5694b (W3-T01..W3-T02 + W3-rev1)
├── w4-serverlog-timeline         1913517 (W4-T01)
└── w5-docs-smoke                 (this worktree, W5-T01..W5-T03)
```

Each wave's review confirmed its branch in isolation
(cross-branch merge happens via PR). Final merge to `main`
is Phase 4 (post-Wave-5) and was deliberately NOT included
in this worktree — the Wave 5 docs work creates the
documentation artefacts and commits them onto `w5-docs-smoke`;
the merge to `main` is a separate decision gate that requires
the full engine + frontend to be green together.

## Sign-off

Wave 5 deliverables shipped:

- `AGENTS.md` new "Connection status & server log (IRCCloud
  parity)" section (155 lines, dense bullet format matching
  the existing "Server features" section).
- `docs/plan/20260716-irccloud-parity/logs/engine-smoke.md`
  — three plan-section-G scenarios documented at code-inspection
  level with file:line evidence + frontend test pinning.
- `docs/plan/20260716-irccloud-parity/logs/visual-smoke.md`
  — five browser smoke scenarios with acceptance-criteria
  traceability and Playwright capture instructions.
- `docs/plan/20260716-irccloud-parity/logs/final-review-summary.md`
  — this document.

Plan status: **SHIPPED** (Wave 5 docs + smoke spec landed;
merge to `main` pending Phase 4 decision gate).