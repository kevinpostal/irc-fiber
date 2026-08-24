# IRC Fiber — Aristotle formal-verification project

This directory holds the Lean 4 mirror of selected IRC Fiber logic that has
been (or is being) formally verified with
[Aristotle](https://aristotle.harmonic.fun/) — the same workflow as the
img2irc and chat-infinite-scroll engagements.

| Path | What it is |
|---|---|
| RequestProject/ | Lean 4.28 lake project (core-only, **no mathlib**). Modules under RequestProject/IrcFiber/ mirror TS sources; sorry = Aristotle obligation. |
| ChatInfinite/ + ChatInfiniteScroll.lean | Delivered chat-scroll verification (no sorries; reference controller reverse-scroll-controller.ts). |
| IRC_SCROLL_SUMMARY.md | Proof journal of the chat-scroll run. |
| ../ARISTOTLE_IMG2IRC_SPEC.md | img2irc formal spec (sorries + proofs). |
| ../ARISTOTLE_STUDY.md | The codebase-wide study: ranked candidates, the RFC1918 finding, backlog. |

## Modules in RequestProject/IrcFiber/

| Module | TS mirror | Proved locally | Aristotle sorries |
|---|---|---|---|
| Ordinal.lean | connectionWarnings.ts ordinalSuffix | 19/19 | 0 |
| Reconnect.lean | wsConnection.svelte.ts backoff/queue/cursor | 16/16 | 0 |
| Suspicious.lean | suspiciousConnection.ts + connectionWarnings.ts | 18/18 (incl. RFC1918 gap proof) | 0 |
| HoleDetector.lean | wsHoleDetector.ts | 6/10 | 4 |
| Splitter.lean | messageSplitter.ts + messageBatcher.ts | 2/8 | 6 |

## Build locally

    cd RequestProject
    lake build IrcFiber.Ordinal IrcFiber.Suspicious IrcFiber.Reconnect IrcFiber.HoleDetector IrcFiber.Splitter

(lake build with no args builds 0 jobs for a library-only package; pass the
module targets explicitly. Sorries build fine — the proofs are checked when
Aristotle replaces them.)

## Submit to Aristotle

See ../../scripts/aristotle/README.md. Current run: project
eb14e53a-e3b7-4e62-8368-e6093f4c59ab (task 1779b5a5-…).

    ../../scripts/aristotle/setup.sh
    export ARISTOTLE_API_KEY=…
    ../../scripts/aristotle/submit.sh
    .venv-aristotle/bin/aristotle tasks eb14e53a-e3b7-4e62-8368-e6093f4c59ab
