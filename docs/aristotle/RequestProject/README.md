# RequestProject — IRC Fiber formalization (Aristotle targets)

Lean 4 (v4.28.0, core-only — no mathlib dependency) mirror of selected
IRC Fiber frontend logic, formally verified with Aristotle (the img2irc and
chat-infinite-scroll workflow).

| module | source mirror | status |
|---|---|---|
| `IrcFiber/Ordinal.lean` | `frontend/src/lib/connectionWarnings.ts` (ordinalSuffix) | fully proved |
| `IrcFiber/Reconnect.lean` | `frontend/src/stores/wsConnection.svelte.ts` (backoff + queue + maxEid) | fully proved |
| `IrcFiber/Suspicious.lean` | `frontend/src/lib/suspiciousConnection.ts` + `connectionWarnings.ts` | fully proved (incl. RFC1918 gap counterexample) |
| `IrcFiber/HoleDetector.lean` | `frontend/src/lib/wsHoleDetector.ts` | fully proved (Aristotle run 1779b5a5) |
| `IrcFiber/Splitter.lean` | `frontend/src/lib/messageSplitter.ts` + `messageBatcher.ts` | fully proved (Aristotle run 1779b5a5; 2 false statements found + corrected) |

All modules: **106 theorems, zero active sorries** (the false originals are
preserved in comments with machine-checked counterexamples). Proof journal:
`docs/aristotle/PROOF_JOURNAL_1779b5a5.md`.

Build (explicit module targets — a library-only package has no default target):

    lake build IrcFiber.Ordinal IrcFiber.Suspicious IrcFiber.Reconnect IrcFiber.HoleDetector IrcFiber.Splitter
