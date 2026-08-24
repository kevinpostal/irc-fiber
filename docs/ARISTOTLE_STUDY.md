# IRC Fiber — Aristotle Formal-Verification Study

> What else in the codebase benefits from [Aristotle](https://aristotle.harmonic.fun/)
> (the formal reasoning agent), after the img2irc and chat-infinite-scroll
> engagements — and what we already shipped with the Aristotle SDK this pass.

Aristotle's sweet spot: code with **subtle invariants**, **bug history**, and a
**pure/functional core** that can be mirrored 1:1 in Lean 4 and checked against
the existing vitest oracles. The two prior engagements hit exactly that:

| Engagement | Source mirror | What was proved | Why it was worth it |
|---|---|---|---|
| img2irc (docs/ARISTOTLE_IMG2IRC_SPEC.md) | frontend/src/lib/img2irc.ts Viterbi/colour core | fullCoverage (no transparent "black holes"), no_hole_for_near_black, empty_preserves_state, trailing_black_not_trimmed | The black-hole bug was a real production defect; the DP collapse proof caught a class of future Viterbi regressions |
| Chat scroll (docs/aristotle/ChatInfinite/) | MessageList/LoadMore reverse infinite scroll | scrollTopPreservedAfterPrepend, noFlickerSameFrame, noGaps, boundedWindow, atBottomStickiness, naivePrependFlickers, progressiveLoadTerminates | Flicker/jump bugs were the top churn area in git history; naivePrependFlickers proves the naive implementation actually flickers |

This pass extends the same playbook to four more blocks (2 S-tier, 2 A-tier),
leaving a ranked backlog for future passes.

---

## 1 · Shipped this pass (Aristotle SDK, project eb14e53a)

Lean project: docs/aristotle/RequestProject/ (Lean 4.28, **core-only — no
mathlib**, so lake build is instant and offline). Ten obligations were left
as sorry for Aristotle; the easy-but-nontrivial maths were proved locally
so the SDK job only sees the genuinely interesting work. **Run 1779b5a5
completed 2026-08-14**: 106 theorems total, zero active sorries — see
docs/aristotle/PROOF_JOURNAL_1779b5a5.md.

| Module | Source mirror (TS) | Status |
|---|---|---|
| IrcFiber/Ordinal.lean | connectionWarnings.ts ordinalSuffix | **19/19 proved locally** (teens rule, 1st/2nd/3rd, 21st/22nd/23rd, 111th/112th/113th…) |
| IrcFiber/Reconnect.lean | stores/wsConnection.svelte.ts backoff + FIFO queue + maxEid cursor | **16/16 proved locally** (schedule 3000 → 6000 → 12000 → 24000 → 30000 → 30000, bounded, monotone, stabilizes at 30 s cap; cursor monotone/idempotent) |
| IrcFiber/Suspicious.lean | lib/suspiciousConnection.ts + connectionWarnings.ts looksLocal | **18/18 proved locally — including a real counterexample, see §2** |
| IrcFiber/HoleDetector.lean | lib/wsHoleDetector.ts | 6/10 proved locally (gap arithmetic, findHole soundness, ring-window size bound); **4 sorries for Aristotle** |
| IrcFiber/Splitter.lean | lib/messageSplitter.ts + lib/messageBatcher.ts | 2/8 proved locally (pack_fits — the 512-byte safety invariant — plus flush_snapshot); **6 sorries for Aristotle** (tiling, chunk bound, greedy optimality, maximality, dropLast) |

### Submit / poll / download (the SDK workflow)

    # one-time
    pip install aristotlelib            # or: uvx --from aristotlelib@latest aristotle …
    export ARISTOTLE_API_KEY=…          # Dashboard → API Keys

    # submit the project (fills sorries); --wait blocks until done
    aristotle submit "$(cat /tmp/aristotle-prompt.txt)" \
      --project-dir docs/aristotle/RequestProject --wait --destination /tmp/aristotle-out.tar.gz

    # or async + poll
    aristotle list                      # → project id
    aristotle show <id>                 # status + recent events
    aristotle tasks <id>                # task list
    aristotle download <id>             # pull the filled project

Scripts: scripts/aristotle/setup.sh, scripts/aristotle/submit.sh (see
scripts/aristotle/README.md). The project also pins leanprover/lean4:v4.28.0
in lean-toolchain so Aristotle builds the exact toolchain used locally.

---

## 2 · Real finding this pass: RFC 1918 coverage gap in looksLocal

connectionWarnings.ts flags "hostname looks local" via string prefixes:

    lower.startsWith('172.16.') || lower.startsWith('172.17.') || lower.startsWith('172.18.') ||
    lower.startsWith('172.19.') || lower.startsWith('172.2') && /^172\.2[0-9]\./.test(lower) ||
    …

RFC 1918 §3 says 172.16.0.0/12 — i.e. **172.16.0.0 – 172.31.255.255**. The
regex trick only covers 172.20–172.29, and the explicit prefixes stop at
172.19. **172.30.0.0/16 and 172.31.0.0/16 are private but never flagged.**

This is now *proved*, not guessed — IrcFiber/Suspicious.lean:

    theorem rfc1918_gap_172_30 : isPrivateRfc1918 172 30 ∧ ¬ codeFlags 172 30 := …
    theorem rfc1918_gap_172_31 : isPrivateRfc1918 172 31 ∧ ¬ codeFlags 172 31 := …

plus the dual soundness theorem (everything the code flags is genuinely RFC
1918 or loopback). **FIXED 2026-08-14** in `connectionWarnings.ts`: the
prefix soup was replaced with a numeric predicate (`isLocalIpv4`) that ports
the Lean `isPrivateRfc1918` spec exactly (10/8, 172.16/12 with the full
16–31 range, 192.168/16, 127/8), so 172.30.0.0/16 and 172.31.0.0/16 are now
flagged. Regression tests added in `connectionWarnings.test.ts` (172.30/31
flagged, 172.32 and 172.2 not, embedded-IP hosts like 127.0.0.1.nip.io still
flagged). The Lean `codeFlags` predicate now serves as documentation of the
historical buggy version.

---

## 3 · The ranked candidate backlog (study of the whole codebase)

### S-tier — already deep-dived this pass

| Block | Files | Why Aristotle pays off |
|---|---|---|
| **WS reconnect controller** | frontend/src/stores/wsConnection.svelte.ts | Backoff schedule (3000 → … → 30000 cap), FIFO send queue with 500-entry guard, monotone maxEid resume cursor. Liveness ("every close schedules exactly one bounded reconnect"), queue no-loss/no-reorder, cursor monotonicity. Mirrors the chat-scroll engagement's value (state machine + liveness). |
| **HoleDetector / OOB gap fill** | frontend/src/lib/wsHoleDetector.ts | Pure sliding-window detector over the eid stream; adjacent to the real 1000-message-burst "0 missing" bugs in git history. Formalizable: findHole soundness, first-pair minimality, window ≤ 20, ascending invariant, cooldown anti-storm. Small enough for a *complete* spec. |

### A-tier — worth a dedicated pass next

| Block | Files | Why Aristotle pays off |
|---|---|---|
| **Message splitter + batcher** | lib/messageSplitter.ts, lib/messageBatcher.ts | The 512-byte IRC protocol budget + greedy pack (adjacent to the already-formalized LambdaPareto/wire model). Safety: every emitted message ≤ maxLen (proved). Interesting: greedy optimality (min message count) — a classic exchange-argument proof. Batcher: snapshot-and-clear flush must not drop/reorder. |
| **Suspicious-connection predicates** | lib/suspiciousConnection.ts, lib/connectionWarnings.ts | Pure boolean logic with a *found bug* (§2). Port sets disjoint; hostname discriminator is total and ordered; RFC1918/loopback classification soundness. Cheap to verify, directly improves prod code. |
| **Banner discriminator** | components/ConnectionStatus.svelte (15 BannerKind branches) | The bannerKind precedence (away → waiting_to_retry → failInfo{5} → queued → joining → ready → quitting → ip-retry → connecting → disconnected) is a total function over the state tuple. Formalize: exactly-one-kind, branch order matches the documented precedence, no dead states. |
| **ISUPPORT splitter disambiguation** | lib/isupportCatalog.ts splitIsupportText | Documented ambiguity rules (e.g. AWAYLEN=307KNOCK) with a unit-test suite. Formalize: the splitter is deterministic, the disambiguation matches catalog lookup, category bucketing is pure (same input → same output). |
| **Engine backoff loop** | engine/source/ircfiber/irc/connection.d (backoff site ~1595) | The D-side retry schedule + waiting_to_retry/zero-clear emits. Liveness: eventually connected or gave up; attemptCount monotone. Higher friction (D → Lean mirror), but the same theorems as the WS controller. |

### B-tier — light-touch candidates (small, self-contained)

| Block | Files | Notes |
|---|---|---|
| ordinalSuffix | lib/connectionWarnings.ts | **Done** — 19 theorems, fully proved (§1). |
| Tab completion cycling | lib/tabCompletion.ts | "Cycling is a permutation over matches, wraps exactly once per cycle". |
| Input history nav | lib/inputHistory.ts | "No duplicate entries; up/down bounded by history length; wraps". |
| WS hole → OOB URL building | lib/wsHoleDetector.ts fetchOOB | Query-string encoding invariant (URL-encodes network id — already pinned by tests). |
| renderReason / renderSSLVerify | lib/connectionWarnings.ts | Small but total: every reason code maps to copy or passes through verbatim. |
| fuzzyMatch scoring | lib/fuzzyMatch.ts | If score monotonicity matters for sorting, worth a proof; otherwise low priority. |

### Already covered — do NOT re-prove

| Area | Where |
|---|---|
| img2irc colour science / Viterbi / glyphs | RequestProject/GlyphCoverage, ViterbiDP, UniformTail/Head, Clustering, LambdaPareto, BoxArmCode (memories 58014ce, bad2f4b) |
| Chat reverse-infinite-scroll | docs/aristotle/ChatInfinite/* + reverse-scroll-controller.ts reference controller |
| uniform safeTrim / ragged edges | UniformTail/UniformHead (used by img2irc + scroll proofs) |

### Not a good fit (Aristotle is not a linter)

- **Svelte component DOM logic** without a pure core (MessageList.svelte's
  event wiring — the *scroll model* is formalized, the DOM plumbing is not).
- **I/O and networking** (fetch, WebSocket transport, Redis) — the models
  are formalizable; the transport itself is not.
- **CSS / visual tokens** (fiber palette work) — nothing to prove.
- **D engine internals with heavy side effects** (connection.d TLS paths) —
  only the pure scheduling/parsing slices (see A-tier) are worth mirroring.

---

## 4 · How to pick the next target (heuristic)

1. Has the module had a **real bug** in git history (flicker, black holes,
   burst "0 missing", MODE-param, DM persistence, 172.30/31)?
2. Is there a **pure function or small state machine** to mirror?
3. Is there an **existing vitest oracle** (test = spec)?
4. Would a **proof survive refactors** (invariant, not implementation)?

If ≥3 hold, it belongs in docs/aristotle/RequestProject/ as a new
IrcFiber/*.lean module + spec doc, then scripts/aristotle/submit.sh.

*Generated 2026-08-14 for IRC Fiber. Aristotle SDK project eb14e53a-e3b7-4e62-8368-e6093f4c59ab.*
