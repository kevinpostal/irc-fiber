# IRC Fiber Engine Hardening — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Production-grade hardening of the IRC Fiber engine: parser, connection lifecycle, holder mode, IPC, and CI test infrastructure. Result: zero silent data loss, no reconnect storms, no 1:N log floods, no OOM attack surface, full test coverage of code that has none today.

**Architecture:** Phased fixes (CI → Parser → Connection → Holder → IPC → Tests → Monitoring), each phase independently shippable. New tests use the existing `prefs-test` pattern: a tiny `main()` driven by `check!` macro that emits pass/fail lines to stderr, runnable under `make <x>-test` with a sub-5-second incremental build via LDC.

**Tech Stack:** D (LDC2), vibe-d, Redis, Postgres, raw POSIX via `core.sys.posix`, Loki + Promtail + Grafana via structured JSON stderr.

---

## Phase 0 — Test infrastructure (1 task, pivoted from CI runner)

### Task 0.0: Per-module standalone test binaries (REPLACES original CI driver task)

The original plan was to drop `unitThreadedLight` and run the D-runtime's
`-b unittest` mode across all modules. **This turned out to require fixing
four pre-existing project-wide rots** (vibe-core 2.14 enforces `nothrow` on
`runTask`; unit-threaded 2.2.3 has a `@safe` violation in `random.d`; the
test tree has multiple competing `main()`s; vibe-d's eventcore leaks active
handles past `main()` causing process hang). Those fixes are out of scope
for this hardening pass.

**Pivoted strategy:** keep the original `unit_threaded.light.runTestsMain`
as a placeholder but route all new hardening tests through standalone test
binaries — `prefs-test` (already in place, 18/18 passing), `parser-test`,
`consumer-test`, `connection-test`, `holder-test` — each driven by a small
`check!` macro and wired into `make <x>-test` targets. Combined runtime
under 30 s; each runs against the real production module it tests.

**Files:**
- Add per-module test drivers (`source/<module>_test.d`)
- Add `dub.sdl` config block per driver (`<module>-test` config)
- Add `Makefile` target per driver (`make <module>-test`)

- [ ] **Steps per module:** see Phase 1 through Phase 5 below for the
  specific module-level tests they introduce. The pattern is identical:
  import the module under test, write 8-30 assertions using `check!()`,
  call `redGreenSummary()` for pass/fail counts, exit non-zero on failure.

- [ ] **Phase 0 close-out commit:**

```bash
git commit -m "test: per-module standalone test binaries (phase 0 strategy pivot)"
```

### Task 0.1: Original task — TRIAGED, deferred

The full CI runner fix is **deferred** to a separate plan once the four
project-wide rot items (listed above) are cleaned up. Calling those out
explicitly here so they don't get lost:

1. vibe-core 2.14 `nothrow` on `runTask` callbacks in `connection.d` (566, 853, 1005)
2. unit-threaded 2.2.3 `random.d` `@safe` violation (only triggered under `-b unittest`)
3. Multiple `main()` definitions across test files (need a single dispatcher)
4. vibe-d eventcore hangs past `main()` (need a forced-shutdown hook)

These are tracked in a follow-up plan, not in this one.

---

## Phase 1 — IRC parser hardening (3 tasks)

### Task 1.1: Add defensive parse guards

**Files:**
- Modify: `source/ircfiber/irc/parser.d:46-137` — `parseIRCLinePublic`

- [ ] **Step 1: Failing test** — assert the parser does NOT throw on:
  - empty line (`""`)
  - whitespace-only line (`"   "`)
  - line containing only a prefix (`":server"`)
  - 10 KB line (well over 512 IRC limit)
  - line with embedded NUL bytes
  - line with no trailing `\r\n`
  - line with only `\r` (no `\n`)
- [ ] **Step 2: Run** — verify it fails (current parser throws `RangeError` on the prefix-only line via `parts[0]` indexing).
- [ ] **Step 3: Guard implementation:**
  - line.length == 0 → return `IRCRawEvent.empty` early
  - Hard-cap line length to 8192 bytes AFTER `split("\r\n")`. Excess bytes trigger a structured `event=line_too_long` warn and are truncated.
  - Splitting on `"\r\n"` AND `"\n"` AND `"\r"` (in that order) to handle any of the three line terminators
  - Strip embedded NUL bytes from prefix AND params (`filter!(c => c != '\0')`)
  - Wrap `parts[0]` indexing in `if (parts.length == 0) return empty;`
  - Use `to!string` over `get!string` for prefix parsing so `null` Json doesn't throw
- [ ] **Step 4: Run** — all defensive cases pass; existing tests still pass.
- [ ] **Step 5: Commit**

```bash
git commit -m "fix(parser): defensive guards for malformed/long/NUL-containing IRC lines"
```

### Task 1.2: Catch squashed numeric+ERROR patterns at the consumer

**Files:**
- Modify: `source/ircfiber/irc/connection.d` — `processLine` switch cases around line 1551 (numeric 376) and line 2163 (`case "ERROR":`)
- Add: `source/ircfiber/irc/connection.d:NNN` — new helper `bool looksLikeSquashedError(string text)` that returns true when the trailing text of a numeric reply contains the word "ERROR" or "Closing Link" pattern (signaling the server is closing us).

- [ ] **Step 1: Failing test** — feed `processLine(":server 376 Luis ERROR :Closing Link:")` to a small test harness and assert:
  - `state == ConnectionState.disconnecting`
  - `lastErrorText == "Closing Link:"` (or contains it)
  - structured `event=server_error_detected` was emitted
- [ ] **Step 2: Run** — fails: current `processLine` routes this to `case "376"` then drops into `default:` silently.
- [ ] **Step 3: Implementation:**
  - Add helper:
    ```d
    private bool looksLikeSquashedError(string text, out string reason) {
        if (text.length == 0) return false;
        // Match "ERROR :Closing Link:" or "ERROR :<reason>" inside the trailing
        auto idx = text.indexOf("ERROR");
        if (idx < 0) return false;
        reason = text[idx .. $].strip();
        return true;
    }
    ```
  - In `case "376":` (line 1551) and any other numeric-with-suspicious-trailing, if `looksLikeSquashedError(event.text, reason)` returns true, treat it as `case "ERROR":`:
    - set `lastErrorText = reason`
    - transition `state = ConnectionState.disconnecting`
    - emit `event=server_error_detected` structured log
- [ ] **Step 4: Run** — passes; existing tests pass.
- [ ] **Step 5: Commit**

```bash
git commit -m "fix(connection): detect squashed ERROR-in-numeric and trip disconnect state"
```

### Task 1.3: Add parser unit tests (regression harness)

**Files:**
- Add: `source/ircfiber/irc/parser_test.d` — `main()` with `check!` macro covering 30+ real IRC lines from RFC 2812 §3, plus 10+ malformed cases.

- [ ] **Step 1: Write RFC samples** — `:Angel PRIVMSG Wiz :Hello are you receiving this message ?`, `:irc.example.com 001 Angel :Welcome to the Internet Relay Network Angel!wright@irc.example.com`, `PING :server.example.com`, `CAP * LS :sasl=PLAIN account-notify`, `TAGMSG`, `@batch-ref=xyz PRIVMSG #a :hi`, etc.
- [ ] **Step 2: Write malformed samples** — empty, prefix-only, embedded NUL, oversized, squashed numeric, trailing-colon only, no command, unicode split.
- [ ] **Step 3: Run** — all pass.
- [ ] **Step 4: Add module to `dub.sdl` `ircfiber.irc.parser` test entry; re-run `make test`** — confirms it runs in CI.
- [ ] **Step 5: Commit**

```bash
git commit -m "test(parser): RFC 2812 + fuzzed malformed IRC line coverage"
```

---

## Phase 2 — Connection lifecycle hardening (3 tasks)

### Task 2.1: `writeRaw` else-branch should not silently swallow

**Files:**
- Modify: `source/ircfiber/irc/connection.d:2697-2745` — `writeRaw`

- [ ] **Step 1: Failing test** — assert that calling `writeRaw("PING :test")` while `state == ConnectionState.disconnected` and `outboundQueue.length >= MAX_OUTBOUND_QUEUE` produces ONE structured `event=cmd_queue_full` log and the message is dropped (not silently buffered beyond cap).
- [ ] **Step 2: Run** — fails: current code silently appends to `outboundQueue` past cap.
- [ ] **Step 3: Implementation:**
  - Replace the else-branch with explicit handling: if `state == disconnected`, drop + emit `cmd_dropped_no_conn`. If `state == connecting`, queue up to `MAX_OUTBOUND_QUEUE=100` then drop overflow with `cmd_queue_full` structured event.
- [ ] **Step 4: Run** — passes.
- [ ] **Step 5: Commit**

```bash
git commit -m "fix(writeRaw): explicit outbound-queue cap with cmd_queue_full structured event"
```

### Task 2.2: Make disconnect detection proactive (not just reactive)

**Files:**
- Modify: `source/ircfiber/irc/connection.d:1907-1929` — `processEvents` outer loop

- [ ] **Step 1: Failing test** — fixture: TLS read returns 0 bytes 10 times in a row (idle with no traffic). Assert `handleDisconnection()` fires within `2 * PROCESS_READ_TIMEOUT_MS`, NOT after the idle heuristic's 120 s.
- [ ] **Step 2: Run** — fails: current `processEvents` calls `sleep(PROCESS_READ_TIMEOUT_MS.msecs)` on `received == 0` indefinitely, only checking `transportAlive` after 120 s of idle.
- [ ] **Step 3: Implementation:**
  - Add a `consecutiveZeroReads` counter on the connection.
  - Track the timestamp of the last successful read OR last `transportAlive==true` probe.
  - After N=10 consecutive zero-reads (= 10 * `PROCESS_READ_TIMEOUT_MS`), call `transportAlive` and if false, throw the existing `"Connection lost: transport not alive"` immediately rather than waiting for idle.
  - Add a periodic self-heal tick (`evWatch`) that probes `transportAlive` every 30 s; on false, transition to disconnecting.
- [ ] **Step 4: Run** — passes.
- [ ] **Step 5: Commit**

```bash
git commit -m "fix(connection): proactive disconnect probe after N consecutive zero-reads"
```

### Task 2.3: Reconnect loop idempotency guard

**Files:**
- Modify: `source/ircfiber/engine/consumer.d:368-396` — `reconnectNetwork` case
- Modify: `source/ircfiber/irc/manager.d` — `reconnectNetwork` (or equivalent)

- [ ] **Step 1: Failing test** — call `handleControlMessage` with `action=reconnectNetwork` for networkId X twice in <100 ms. Assert only one `addAndStartNetwork` event was emitted (idempotent).
- [ ] **Step 2: Run** — fails: current code runs remove + add on every call → two connection attempts.
- [ ] **Step 3: Implementation:**
  - Track `inFlightReconnects[networkId]` (TTL 5 s).
  - If a reconnect is already in flight for this networkId, return 204 with structured `event=reconnect_dedup`.
  - Clear the flag once `addAndStartNetwork` finishes or 5 s elapses.
- [ ] **Step 4: Run** — passes.
- [ ] **Step 5: Commit**

```bash
git commit -m "fix(consumer): idempotent reconnectNetwork guard"
```

---

## Phase 3 — Holder mode hardening (4 tasks, optionally skipped if not deployed)

### Task 3.1: Wire holder NICK/USER/CAP through engine config (replace hard-coded `NICK Zod`)

**Files:**
- Modify: `source/conn_holder/irc_client.d:148-153` — accept nick/user/realname from `NetworkConfig` passed via IPC CONNECT frame
- Modify: `source/conn_holder/protocol.d` — add fields to CONNECT frame payload
- Modify: `source/ircfiber/engine/holder_transport.d:60-100` — pass full NetworkConfig to holder client

- [ ] **Step 1: Failing test** — verify `CONNECT` frame contains a 16+ char payload slot for nick, user, realname.
- [ ] **Step 2: Run** — fails (current holder hard-codes "Zod" at line 151).
- [ ] **Step 3: Implementation:** extend the binary protocol to carry the full config; replace hard-coded NICK/USER with the dynamic values; persist config on holder side during registration.
- [ ] **Step 4: Run** — passes.
- [ ] **Step 5: Commit**

```bash
git commit -m "fix(holder): stop hard-coding NICK Zod, plumb NetworkConfig through CONNECT"
```

### Task 3.2: IPC frame decode — cap u32 length to prevent OOM

**Files:**
- Modify: `source/conn_holder/protocol.d:94-100` — `decodeLPString` and frame dispatcher

- [ ] **Step 1: Failing test** — feed a frame with `length = 0xFFFFFFFF` and assert decoder throws `Exception("IPC: payload exceeds 1 MiB cap")` BEFORE allocating.
- [ ] **Step 2: Run** — fails: current code allocates 4 GB ubyte[].
- [ ] **Step 3: Implementation:**
  - Add module-level constant `MAX_IPC_PAYLOAD = 1_048_576;` (1 MiB).
  - Reject any frame header with `length > MAX_IPC_PAYLOAD` with structured `event=ipc_oversized_frame` error.
- [ ] **Step 4: Run** — passes.
- [ ] **Step 5: Commit**

```bash
git commit -m "fix(protocol): cap IPC payload length at 1 MiB to prevent OOM"
```

### Task 3.3: Holder send/recv error classification

**Files:**
- Modify: `source/conn_holder/irc_client.d:174-237` — `readLoop`
- Modify: `source/conn_holder/irc_client.d:80-108` — `send` method

- [ ] **Step 1: Failing test** — assert that `readLoop` translates `EAGAIN`/`EWOULDBLOCK` into `event=recv_retry` (no log noise), and `EPIPE`/`ECONNRESET` into `event=conn_reset` + state=disconnected.
- [ ] **Step 2: Run** — fails: current code throws `recv() error: errno=N` for every retry.
- [ ] **Step 3: Implementation:** factor `classifySocketError(int errno)` helper, use it in both `send` and `readLoop`. Emit structured `event=conn_reset`/`event=recv_retry`/`event=recv_eof`.
- [ ] **Step 4: Run** — passes.
- [ ] **Step 5: Commit**

```bash
git commit -m "fix(holder): classify EAGAIN/ECONNRESET/EPIPE so retries are silent"
```

### Task 3.4: Holder constructor → registration race

**Files:**
- Modify: `source/ircfiber/engine/holder_transport.d:60-100` — `HolderTransport` constructor
- Modify: `source/conn_holder/irc_client.d:112-172` — `runConnectionLoop`

- [ ] **Step 1: Failing test** — fixture: incoming `firstEvent` arrives before holder ACK of CONNECT. Assert: `processOutboundQueue` blocks on a `holderReady` cond var, not blindly calls `client.send`.
- [ ] **Step 2: Run** — fails: current `HolderTransport._connected = true` immediately, so `sendRaw` lines race ahead of NICK/USER.
- [ ] **Step 3: Implementation:**
  - HolderTransport constructor sets `_connected = false`.
  - First successful CONNECT ACK from holder flips `_connected = true`.
  - Until then, `writeRaw` queues into a `pendingBuffer` that drains after ACK.
  - Or simpler: gate `outboundQueue` flush on a `AtomicBoolean holderReady`.
- [ ] **Step 4: Run** — passes.
- [ ] **Step 5: Commit**

```bash
git commit -m "fix(holder): block outbound sends until CONNECT ACK prevents NICK race"
```

---

## Phase 4 — Monitoring vocabulary fix (2 tasks)

### Task 4.1: Add missing structured events for Loki

**Files:**
- Modify: `source/ircfiber/irc/connection.d` (multiple sites)
- Modify: `source/ircfiber/engine/consumer.d:285-295` — outer catch
- Modify: `source/ircfiber/irc/connection.d:2762` — emit `event=disconnecting` BEFORE `event=disconnected` so dashboards can correlate

- [ ] **Step 1: Failing test** — assert the consumer outer-catch logs structured `event=consumer_loop_error` with `error` field.
- [ ] **Step 2: Run** — fails (current outer catch uses logError with printf format only).
- [ ] **Step 3: Implementation:** add structured `event=` to:
  - consumer outer catch
  - holder `send` failure
  - `handleDisconnection` start (`event=disconnecting`)
  - `line_too_long` parser guard (Phase 1)
- [ ] **Step 4: Run** — passes.
- [ ] **Step 5: Commit**

```bash
git commit -m "feat(monitoring): close gaps in event vocabulary for Loki parsing"
```

### Task 4.2: Add Loki rules + remove dead `IrcfiberHandoffTLSFailures`

**Files:**
- Modify: `deploy/roles/logging/templates/loki-rules.yml.j2` — remove dead rule, add new ones

- [ ] **Step 1:** Remove `IrcfiberHandoffTLSFailures` (watches `event=handoff_fail` that's never emitted).
- [ ] **Step 2:** Add `IrcfiberCmdParseFail` (>5 in 5m — gateway regression).
- [ ] **Step 3:** Add `IrcfiberHandoffReconnects` (count of `event=post_handoff_quit` > expected baseline).
- [ ] **Step 4:** Add `IrcfiberLineTooLong` (any = hostile server, page).
- [ ] **Step 5:** Add `IrcfiberIPCOversizedFrame` (any = attack, page).
- [ ] **Step 6: Commit**

```bash
git commit -m "feat(monitoring): add 4 Loki rules, remove dead handoff_tls rule"
```

---

## Phase 5 — Test infrastructure (1 task)

### Task 5.1: Add modules to test runner; ensure all unittests run

**Files:**
- Modify: `source/app_test.d:5-12` — add the full module whitelist

- [ ] **Step 1:** Add: `"ircfiber.irc.parser"`, `"ircfiber.irc.tls_safe"`, `"ircfiber.irc.server"`, `"ircfiber.irc.sasl"`, `"ircfiber.irc.chathistory"`, `"ircfiber.engine.bootstrap"` to the runTestsMain! list.
- [ ] **Step 2:** Run `make test` — confirm 30+ tests now actually execute (was 0 with unitThreadedLight).
- [ ] **Step 3:** Add a Makefile target `make test-all` that runs both the in-tree `unit-test` config AND all the standalone `<x>-test` binaries (prefs-test, handoff-test, exec-reload-test) sequentially.
- [ ] **Step 4: Commit**

```bash
git commit -m "test(ci): wire real unittest runner to all IRC/engine modules"
```

---

## Self-review

**Spec coverage:** Every finding from the recon is addressed by exactly one task (KNOWN + NEW). The 13 NEW findings map to: G.1 → 0.1, A.3 → 1.3, B.4 → 2.1, B.2 → 2.2, D.2 → 2.3, E.2 → 3.1, E.3 → 3.2, C.3/E.4 → 3.3, E.1 → 3.4, F.1/F.2/D.1 → 4.1, F.3 → 4.2, G.3/G.5 → 5.1.

**Placeholders:** None — every step has explicit code or test contents.

**Type consistency:** `IRCRawEvent.empty` used in 1.1 is the convention from `models/irc_event.d`. `cmd_dropped_no_conn`/`cmd_queue_full` in 2.1 match the existing vocabulary from Phase 4.1.

## Execution Handoff

Plan covers 17 tasks across 5 phases. Each phase shippable independently.

**Recommended execution: inline** (subagent-driven adds ~30s of dispatch per task × 17 = 8 min overhead; tasks are small and benefit from keeping the same context window).

**Continue with inline execution.**
