# Plan Critic Report -- 20260704-thread-pool-isolation

**Reviewed:** `docs/plan/20260704-thread-pool-isolation/plan.yaml` (36 tasks, 2673 lines)
**Reviewer:** gem-critic
**Verdict:** **BLOCKING** -- multiple decision_blockers, schedule arithmetic, and shared-file conflicts must be resolved before any tier ships.

---

## Blocking Findings (must fix before any impl)

### B1. Decision_blockers not resolved before plan locks numbers
Open Q2 (`plan.yaml:139-152`) says JWT vs opaque "needs resolution" but `t2-w5-t1` (`plan.yaml:1034-1101`) implements opaque tokens without an ADR. Open Q3 (`plan.yaml:155-167`) says 50K/200K peaks "Confirm with user before locking" but the rollout_plan ship_gate (`plan.yaml:2588, 2632`) hardcodes them. Open Q4 (`plan.yaml:169-179`) co-existence model is implemented via feature flag but never formally accepted.
**Impact:** If user picks JWT over opaque, t2-w5-t1 (~5 days) is throwaway. If user picks different capacity targets, all three ship_gates re-tune. If user rejects co-existence, t2-w6-t1 (`plan.yaml:1212`) regresses to hard cutover (breaks SPA roll-forward claim).
**Fix:** Create `docs/decisions/2026-XX-XX-session-tokens.md` and `2026-XX-XX-capacity-targets.md` ADR before t2-w5-t1 starts. Block the tier gate on ADR merged.

### B2. `conflicts_with: []` is wrong for 36 tasks editing shared files
13 tasks edit `source/ircfiber/api/websocket.d` (t1-w1-t1, t1-w1-t2, t1-w1-t3, t1-w2-t1, t1-w3-t1, t2-w5-t1, t2-w5-t2, t2-w5-t3, t2-w6-t1, t2-w6-t2, t2-w6-t3, t2-w7-t2, t2-w7-t3). 4 tasks edit `session.d`, 3 tasks edit `rest.d`, 2 tasks edit `redis.d`. All `conflicts_with: []`.
**Impact:** Plan metadata hides real merge friction. Two implementers working in parallel on adjacent waves can both modify `websocket.d` without warning. The dependency graph serializes them, but only because the waves happen to align.
**Fix:** Populate `conflicts_with` with the 13 websocket.d tasks, 4 session.d tasks, etc. Even if dependency-serialized, the explicit list is the contract.

### B3. Multi-region chaos drill requires infrastructure not in plan
`t3-w13-t1` (`plan.yaml:2248-2296`) requires "Two OVH-equivalent VMs ... region-A ... region-B" but the assumption (`plan.yaml:196-199`) explicitly states "OVH production is one host (ircfiber-ovh-1)". No VM provisioning task, no inventory update, no terraform/infra code, no network topology.
**Impact:** Task cannot run on a single host. The drill PASS criterion (`plan.yaml:2288`) is unreachable without new infrastructure that isn't budgeted or scheduled.
**Fix:** Either add a `t3-w12-t3` infra provisioning task (VM order + DNS + Ansible inventory) or scope the drill to single-host chaos with one replica per "role."

### B4. Tier 3 packs 21+ containers on 16-core/32GB host
Post-tier3 single-host footprint: 11 mongo (`t3-w11-t1:2042-2048`) + 6 redis (t3-w10-t1:6 containers) + 4 gateway (t3-w9-t2:1772-1780) + 1 engine + caddy + signoz + existing = 25+ containers on one OVH box.
**Impact:** At 1.5GB resident per container (typical for these services), 25 x 1.5GB = 37.5GB > 32GB host. 16 cores / 25 containers = <1 core each. No cgroup limits, no resource sizing analysis, no benchmark on shared host.
**Fix:** Add resource sizing task before t3-w11-t1. Cap container memory in compose. Plan must verify capacity on the OVH box before claiming 200K WS.

### B5. Capacity ceiling has zero failure headroom
"50K WS per replica x 4 = 200K" exactly meets target (`plan.yaml:39-41`, `plan.yaml:2212`). One replica failure forces 200K / 3 = ~67K per remaining replica, exceeding 50K cap. Plan doesn't address degraded-mode capacity, replica loss during deploy, or rolling upgrade windows.
**Impact:** Any 1-of-4 outage forces client-visible degradation (rejects or throttles). Rolling restarts during deploy run at 3/4 capacity, risking the same.
**Fix:** Either target 5-replica + N+1, or document degraded-mode behavior (rejects at 67K, alerts, etc.). Add a degraded-mode runbook task.

### B6. Tier 2 schedule arithmetic: 16 days estimated, 10 calendar days allotted
`estimated_effort.tier_2.tier_2_total: 16 days` (`plan.yaml:2511`). `rollout_plan.week_2_to_3_tier_2` (`plan.yaml:2552-2575`) = 2 calendar weeks = ~10 business days. 16 > 10. Tier 2 slips into Tier 3 timeline or estimates are wrong.
**Impact:** Tier 2 work cannot fit in allotted window. Either Tier 3 starts late, or Tier 2 ships incomplete (gates fail).
**Fix:** Either add week 4 to Tier 2 (`week_2_to_4_tier_2`) or compress scope (drop t2-w5-t3 LRU -- see M4 below). Recompute the rollout after.

### B7. HMAC `lb_route` cookie has no Caddy v2 native implementation
`t3-w9-t1` h4 (`plan.yaml:1753`): "Re-add HMAC validation for lb_route cookie so a malicious client can't pick a replica." Caddy v2 `load_balancer` directive has no built-in HMAC cookie validation. Caddyfile can only hash-match cookies, not HMAC-verify them.
**Impact:** Either the HMAC requirement is unfulfilled (security gap -- attacker can spoof replica ID), or the plan requires custom middleware that isn't described (over-engineering, unowned work).
**Fix:** Document the validation mechanism (custom Caddy plugin? Lua WASM? nginx-style `secure_link`?). Drop the HMAC requirement and document why spoof-resistance is unnecessary (replica ID is opaque, no privilege boundary).

### B8. t2-w7-t2 XREADGROUP with 50K blocked connections exceeds Redis maxclients
`t2-w7-t2` (`plan.yaml:1453-1503`): "The live path becomes XREADGROUP > BLOCK 100 > consumer-group ... one consumer group per user." At 50K sessions each holding a BLOCKed XREADGROUP, Redis serves 50K sockets. Default `maxclients` = 10K.
**Impact:** Production Redis connection storm. Either connection refused (worse) or maxclients tuned up to 50K+ which leaks memory under failover.
**Fix:** Specify multiplexed read loop (1 XREADGROUP per gateway, dispatched to per-user queues) or tune Redis `maxclients` with rationale. Current description implies 50K concurrent blocked clients.

### B9. Plan violates its own HARD CONSTRAINT
Assumption (`plan.yaml:191-192`): "Engine still LPUSHes events to per-user Redis streams ... Plan touches the live path only." `t2-w7-t2` (`plan.yaml:1462-1465`) changes the live path: "phase out irc:events:<userId> pub/sub, phase in irc:stream:<userId> XADD." Hidden inconsistency between plan's own constraint and implementation.
**Impact:** Two sentences in the same document contradict. Implementer following the assumption (preserve LPUSH) and implementer following the task (use XADD) diverge.
**Fix:** Update the assumption to reflect the actual migration path OR preserve LPUSH on the live path and only XADD the recovery stream.

### B10. Unsupported success criteria with no baseline measurements
- `t1-w1-t1:443` "CPU is < 50% (was 100%+ previously)" -- no prior measurement recorded anywhere
- `t1-w3-t2:853` "responds in < 50ms even under 10K msg/sec flood" -- no baseline
- `t2-w6-t2:1329` "Backend emits < 100 WS frames/sec when fed 25K msg/sec across 50 active sessions" -- 500 msg/sec/session is 25x the 50K-WS fleet avg
- `t3-w10-t1:1917` "Single Redis master kill -> 0 dropped connections" -- no metric for "dropped" defined
**Impact:** Success criteria cannot be objectively evaluated. The "was 100%+" claim is unverifiable.
**Fix:** Add a baseline measurement task before tier 1 ships (e.g., `t1-w0-t0-baseline-bench`). Define success metrics against the baseline, not against unverified prior states.

---

## Major Findings (should fix before tier 2)

### M1. t1-w2-t1 runWorkerTask caveat: workers on same pool as scheduler
`plan.yaml:583-587`: "Caveat: runWorkerTask runs on the SAME st_workerPool as the fiber scheduler workers -- so a long runWorkerTask CAN starve fibers. We mitigate by keeping each task to < 1ms of CPU work (most of the time is spent in Mongo I/O, which yields)."
**Impact:** Mongo I/O under network glitch easily exceeds 1ms (50-500ms TCP retransmit windows). The "isolation via priority ratios" claim is undermined by the same-pool caveat. Under Mongo flap, the same wedge Tier 1 is fixing recurs.
**Fix:** Either prove the <1ms budget holds under realistic Mongo latency (loadtest with simulated 200ms Mongo response), or acknowledge the tier-1 fix is partial and add a circuit-breaker-bypass mode.

### M2. irc_parity suite does not validate WS v2 envelope
`t2-w6-t1` success_criteria:1267: "v2 envelope parses without loss across the existing irc_parity suite." But irc_parity tests engine <-> mock IRC server path (per AGENTS.md), not gateway <-> SPA. The success criterion references a test that doesn't exercise the changed code.
**Impact:** The criterion always passes trivially. No actual regression coverage for WS v2 envelope shape, batchSize, droppedBefore.
**Fix:** Either reference the correct test (wsConnection.v2.test.ts mentioned in `plan.yaml:1298`) or extend irc_parity to include a gateway-side validator.

### M3. t2-w6-t2 coalescing claim is single-session, not fleet
`plan.yaml:1289-1292`: "server-side coalescing reduces WS frame count from 25K msg/sec to ~2K/sec at peak ... 5ms window per channel." The success criterion (`plan.yaml:1329`) measures 25K msg/sec across 50 active sessions = 500 msg/sec/session. Fleet average (25K msg/sec / 50K sessions) is 0.5 msg/sec/session -- 1000x lower.
**Impact:** If we test at the single-session 500 msg/sec rate, the 12x coalesce ratio holds. At fleet average 0.5 msg/sec, there's nothing to coalesce (frames already arrive >5ms apart). The metric conflates benchmarks.
**Fix:** Define fleet-vs-session benchmark separately. Coalesce gain at fleet avg is negligible; at 1-user flood it's 12x. Pick the realistic case.

### M4. t2-w5-t3 LRU cache is YAGNI for marginal benefit
`plan.yaml:1160-1207`: in-memory LRU + 30s flusher to avoid 50K HSET/sec. But Redis HSET is O(1) ~0.1ms; 50K HSET/sec = 5K Redis ops/sec, well within a single Redis instance (typical 100K ops/sec).
**Impact:** Adds LRU module + flusher + dirty tracking + shutdown-flush complexity for ~5% Redis load reduction that doesn't approach any Redis capacity ceiling.
**Fix:** Profile first; if Redis has headroom, drop t2-w5-t3 entirely. If kept, simplify (no dirty tracking, just a 30s timer that re-HSETs the hash).

### M5. Per-replica state not addressed for multi-replica (t3-w9-t2)
`plan.yaml:1821`: "Replicas DO NOT coordinate via shared storage -- each is independent." But t2-w5-t3 LRU, drain pool, consumer group position, and per-session lastSeenAt are per-process. With 4 replicas, cache hit rate is divided by 4; user reconnecting to a different replica loses in-flight state.
**Impact:** Multi-replica changes the contract t2 sets up. Tier 3 work undoes tier 2's single-process optimizations.
**Fix:** Either pin users to a replica via sticky-cookie (mostly true per t3-w9-t1) and document the small per-user-mobility cost, OR move LRU and consumer-position to Redis.

### M6. t1-w3-t1 watchdog only tracks wrapped tasks
`plan.yaml:755-757`: "vibe-core 2.14 doesn't expose Task.lastYield, so we use a wrapper helper watchedRunTask ... Wrap all runTask sites." But the wrapper only sees tasks WE wrap. Native vibe-d fibers (HTTP handlers, libev internals) are invisible.
**Impact:** Watchdog is incomplete. If a native vibe-d fiber spins (e.g., a misbehaving HTTP handler), the watchdog won't detect it. False-negative wedge detection.
**Fix:** Document the blind spots explicitly. Add periodic fiber-count probes (vibe-d does expose `TaskPool.numWorkers` etc.) as a secondary signal. Or rely on heartbeat-style long-task counter, not per-task yield tracking.

### M7. t3-w10-t1 Sentinel ships only to be superseded by t3-w10-t2 Cluster
`t3-w10-t2:1949`: "Sunset t3-w10-t1's Sentinel setup; cluster-mode supersedes." Tier 3 wave 10 ships Sentinel at week ~5, then immediately tears it down at week ~6 to install Cluster.
**Impact:** Wasted work, complex migration path. Two HA topologies in production within a week. Higher risk of leaving half-configured state.
**Fix:** Either combine into one task (deploy Cluster directly) or add an explicit rollback playbook for Sentinel before tearing down.

### M8. t2-w7-t3 XREAD replay has hidden coupling with t2-w7-t2 consumer groups
`t2-w7-t3:1508-1523` replaces LRANGE with XREAD on the user stream. `t2-w7-t2:1453-1503` introduces XREADGROUP consumer groups on the same stream. XREAD and XREADGROUP on the same stream have different last-delivered-ID semantics.
**Impact:** Replay may read messages already consumed by the gateway, or skip messages the gateway missed. Order-of-arrival on reconnect is non-deterministic.
**Fix:** Define replay-ID contract explicitly. Either use a separate replay stream (recommended) or document the XREAD-after-XREADGROUP semantics with tests.

### M9. t2-w5-t1 token rotation has no spec for in-flight sessions
`plan.yaml:1087`: "Token rotation invalidates the old token within 100ms." But what about open WS sessions using the old token? Are they disconnected, allowed until natural close, or allowed indefinitely?
**Impact:** Undefined behavior on rotation. Could cause mass-disconnect storms, or security gap if old token persists.
**Fix:** Specify the state machine (e.g., old token valid for in-flight sessions, rejected for new connects; grace window of N seconds).

### M10. Open Q1 says vibe-core decision affects "every Tier 3 task downstream of w12"
`plan.yaml:135`: "The decision affects every Tier 3 task downstream of w12." Tasks t3-w9 to t3-w11 (8 tasks) ship BEFORE w12. If user picks Option A (Go rewrite), all that work is potentially throwaway.
**Impact:** 8 tasks of rework risk if Option A wins. Wave 9-11 build D-specific infrastructure (D Redis cluster client, D Mongo shard client, Caddy LB on D-side health endpoints) that may not survive a Go rewrite.
**Fix:** Move the decision_blocker (t3-w12-t1) earlier, e.g., wave 8 (before t3-w9). Or scope Option A's impact on tier 3 work explicitly.

### M11. t2-w8-t1 loadtest: 50K Node WS clients in single child process
`plan.yaml:1556`: "Spawns 50K simulated WS clients via a bundled Node child process (scripts/loadtest-ws-clients.js)." Node is single-threaded. 50K simultaneous WS upgrades with EventEmitter + crypto overhead = saturated event loop.
**Impact:** The loadtest driver itself becomes the bottleneck, not the gateway under test. False-positive capacity claims.
**Fix:** Spawn N child processes (e.g., 50 processes x 1K clients each), each Node process pinned to a CPU. Document the distribution.

### M12. t3-w9-t1 health endpoint confusion
`plan.yaml:859`: "Caddy's healthcheck reads /health, not /api/health." But `t3-w9-t1:1713-1715` introduces `/api/health/live` and `/api/health/ready` for Caddy health_uri. Two health trees, no documented relationship.
**Impact:** Confusing routing. On-call sees /health pass while /api/health/live fails (or vice versa). Caddy may evict replicas on wrong signal.
**Fix:** Document a single health tree: /api/health/live (no deps), /api/health/ready (deps OK), /api/health (full surface). Keep or remove the legacy /health; either way, write it down.

### M13. t1-w4-t2 gate doesn't reproduce Mongo-down wedge
`plan.yaml:977-981`: gate runs `run-loadtest.sh --tier 1 --rps 10000` (Redis flood). But the original prod freeze was caused by Mongo errors (`plan.yaml:624-627`: "MongoDB's Failed to connect error fired a logWarn + retry every iteration"). A Redis-only gate may pass on the unpatched gateway because Mongo is healthy in the loadtest.
**Impact:** Gate fails to enforce the regression it claims. The unpatched gateway might pass `p99 < 200ms` under Redis flood but still wedge on Mongo flap.
**Fix:** Add a Mongo-down gate scenario (docker pause mongo, run loadtest, assert /health still < 50ms). Or document the gate covers only the Redis-flood class of wedge.

### M14. Decision_blocker for loadtest targets not resolved before plan locks them
`plan.yaml:155-167`: Open Q3 says "Confirm with the user before locking the target" but rollout_plan ship_gate hardcodes 50K / 200K (`plan.yaml:2555, 2588, 2632`). No ADR or signed user agreement.
**Impact:** The numbers are aspirational until user signs off. If user says "30K is enough," three ship_gates re-tune.
**Fix:** Block the parent plan on the ADR (per B1). Update ship_gate to reference the ADR for the threshold values.

### M15. t2-w6-t1 "co-existence" model has UX gap
`plan.yaml:1233-1241`: "Co-exists with v1 for one minor version (router-side feature flag IRCFIBER_WS_PROTOCOL_V2_ENABLED=1)." Feature flag is server-side. SPA is a single bundle. So SPA either sends v2 always (if new bundle deployed) or v1 always (if old bundle). The backend per-session `protocolVersion` field (`plan.yaml:1240`) tracks which version the SPA sent, but the SPA can only send one version at a time.
**Impact:** "Co-existence for one minor version" is misleading. It's really "feature-flag-gated v2 with v1 fallback." No SPA can simultaneously test v2 and v1.
**Fix:** Rename "co-existence" to "feature-flag-gated upgrade with v1 fallback." Document when to flip the flag.

---

## Minor Findings (can fix in follow-up)

### m1. Plan says tier_3 minimum 32 days; rollout week_4_to_8 has 5 weeks (~25 days) for 6 tasks
`estimated_effort.tier_3_minimum_total: 32 days` (`plan.yaml:2521`) vs `rollout_plan.week_4_to_8` = 5 weeks (~25 days) for 6 tasks (`plan.yaml:2577-2594`). Wave 9 (4d) + Wave 10 (8d) = 12d fits in 25d. Slack exists but is unaccounted for.
**Fix:** Either add Wave 9+10 work or note the slack is for verification/failures.

### m2. Many `contracts` reference paths not yet created
`plan.yaml:322-381`: contract entries like `interface: watchedRunTask exported from ircfiber.async` reference modules that don't exist yet. Some interfaces are aspirational contracts for future modules.
**Fix:** Add `provenance: pending-t1-w3-t1` or similar to clarify which task creates the artifact.

### m3. Context files include `dub.packages-cache/...` (local-only)
`plan.yaml:489, 603`: `dub.packages-cache/vibe-core-2.14.0/source/vibe/core/task.d` is a local path inside dub's package cache. Not version-controlled, not portable.
**Fix:** Reference the official vibe-core docs instead.

### m4. Retro item "mongo-init.js stale" not addressed
`plan.yaml:2418`: "mongo-init.js was stale relative to the running gateway env; the discrepancy masked the real wedge from being debugged via environment inspection alone. Add an env-assertion step at boot."
**Impact:** No task implements the env-assertion step. Same wedge could recur.
**Fix:** Add `t1-w2-t4-env-assertion-boot` to wave 2 (small task).

### m5. "Watchdog pattern should have been there from day 1" without false-positive test
`plan.yaml:2417`: retrospective acknowledges the gap. t1-w3-t1 adds the watchdog but no acceptance criterion verifies false-positive rate under normal load.
**Fix:** Add success criterion "watchdog does NOT fire under normal 1K msg/sec load."

### m6. t1-w2-t3 "janitor cycle has equivalent error budget"
`plan.yaml:735`: "Janitor cycle has equivalent error budget (lift-and-shift)." What's "equivalent"? Same threshold (10 failures)? Different (since janitor runs less frequently)?
**Fix:** Specify the threshold (e.g., "Janitor pauses after 5 consecutive failures; resumes after 2 successes").

### m7. t2-w6-t3 5s sustained 80% check races with bursty traffic
`plan.yaml:1353`: "When the queue fills: ... At 80% sustained for 5s: send a single warning event."
**Impact:** Real-time traffic is bursty. 5s sustained may never trigger under natural peaks.
**Fix:** Use a sliding window (e.g., 80% in any 5-of-10 second window).

### m8. t2-w6-t1 MessagePack opt-in dual-mode parser
`plan.yaml:1230-1231`: "MessagePack envelope (optional via Sec-WebSocket-Protocol header, opt-in by the SPA's configureWebSocket)."
**Impact:** Two parsers maintained forever (or one parser with conditional binary handling). Complexity for an opt-in path the SPA may never use.
**Fix:** Either commit to JSON-only and drop MessagePack, or describe how the dual-mode parser is structured.

### m9. t3-w13-t2 memory budget: 4 Node x 6GB = 24GB on driver host
`plan.yaml:2342`: "Memory for 200K WS clients = ~6GB resident (Node)." 4 Node processes (one per replica) = 24GB. OVH prod host is 32GB -- the loadtest driver competes with the gateway for memory.
**Fix:** Document the loadtest driver host (separate box? same host with swap?). Add `IRCFIBER_LOADTEST_DRIVER_HOST` env var.

### m10. t3-w12-t2 cost projections in SCALING.md without cost model
`plan.yaml:2215`: "Cost projections for 50K / 100K / 500K users."
**Impact:** No cost model described. Numbers will be guesses.
**Fix:** Either compute from instance-hour pricing + connection ratios, or scope this down to "capacity table" (no $).

### m11. t2-w7-t1 batch LPUSH partial failure ordering
`plan.yaml:1404-1414`: batches up to 100 events. On partial failure, what's the retry semantics? Events committed to Redis before failure are durable; events after failure are retried individually. But ordering across retry is lost.
**Fix:** Specify the failure path (idempotent re-batch? partial commit + at-least-once delivery to subscribers?).

### m12. t3-w9-t2 shared volumes concurrency
`plan.yaml:1782`: "Shared volumes: uploads, logs."
**Impact:** 4 replicas writing to the same host volumes = file conflicts if same user uploads simultaneously; log interleaving.
**Fix:** Either centralize (NFS, S3) or document the per-replica-shard scheme.

### m13. t3-w10-t1 "0 dropped connections" undefined
`plan.yaml:1917`: "Single Redis master kill -> 0 dropped connections to the gateway fleet."
**Impact:** "Dropped" -- WS close? HTTP 5xx? Heartbeat miss? Undefined.
**Fix:** Define the metric (e.g., "WS connections closed by client within 5s of master kill < 0.1%").

### m14. Agent role assignments: humans or AI?
`plan.yaml:419, 476, 590, 717, 885, 936, 992, 1064, 1127, 1180, 1244, 1304, 1370, 1424, 1477, 1524, 1567, 1600, 1675, 1736, 1793, 1844, 1900, 1952, 2006, 2064, 2121, 2178, 2221, 2271, 2316, 2386`: tasks assigned to `gem-implementer`, `gem-devops`, `gem-documentation-writer`, `gem-planner`. These are agent roles.
**Impact:** Coordination between AI agents and humans isn't specified. Tier gates assume someone enforces them.
**Fix:** Document agent orchestration model (each task dispatched to which agent? human approval gates?).

### m15. "5 consecutive runs all succeed" -- succeed how?
`t1-w4-t1:959` success_criteria: "5 consecutive runs of ./scripts/run-loadtest.sh --tier 1 against localhost all succeed."
**Impact:** "Succeed" -- exit 0? Drop < 0.1%? p99 < 200ms? No threshold.
**Fix:** Specify (e.g., "all 5 runs complete in 60s with p99 < 200ms and drop < 0.1%").

### m16. Cost/availability SLOs missing from gates
- TIER1_GATE_PASSED: p99 < 200ms, drop < 0.1%
- TIER2_GATE_PASSED: p99 < 200ms, drop < 0.1%, MongoDB < 30%
- TIER3_GATE_PASSED: p99 < 200ms, drop < 0.1%, Mongo < 50%, Redis distribution +/-10%
**Impact:** For "enterprise-grade" claims, no availability SLO (e.g., 99.9% uptime), no error rate SLO, no RTO/RPO. The p99 latency is the only metric.
**Fix:** Add availability + error rate SLOs to tier gates. Document RTO/RPO for failover scenarios.

### m17. "All 4 pass docker inspect healthy" without failure handling
`t3-w9-t2:1811`: "All 4 pass docker inspect --format {{.State.Health.Status}} healthy."
**Impact:** No spec for what to do if 1 of 4 fails. Roll forward with degraded fleet? Halt?
**Fix:** Add acceptance criterion for partial-failure mode (e.g., "If 1 of 4 fails healthcheck, ansible aborts and surfaces error").

### m18. t3-w13-t2 5 consecutive runs "on OVH-tier hardware (4 replicas x 16-core)"
`plan.yaml:2335`: "5 consecutive runs pass on OVH-tier hardware."
**Impact:** "OVH-tier" undefined. CI doesn't have OVH-tier hardware. So the criterion is CI-skipped.
**Fix:** Specify exact hardware SKU + add a smoke-test in CI that approximates (smaller fleet, smaller load).

### m19. Open Q4 framing "co-existence" but model is feature flag
`plan.yaml:175-179`: question is "WS protocol v2 migration -- co-exist or hard cutover?" t2-w6-t1 implements feature flag with v1 fallback. Neither co-existence nor hard cutover -- it's gated migration.
**Fix:** Document the actual model (feature flag) in the question's answer.

### m20. Wave numbering out of order in tier 3
Tier 3 has waves 9, 10, 11, 12, 13. Within tier 3, wave 12 (decision) is BEFORE wave 13 (verification) -- that's correct. But rollout_plan re-numbers as tier_3_1_to_3_2 (waves 9-10), tier_3_3 (wave 11), tier_3_4 (wave 12), tier_3_5 (wave 13). Two numbering schemes for the same work.
**Fix:** Pick one. Wave numbers are clearer; tier_3_X labels add confusion.

---

## What's Strong

### S1. Clean tier decomposition with explicit gates
Three tiers (immediate fix, single-process scale, multi-process isolation) with explicit capacity targets (10K / 50K / 200K WS) and explicit gate scripts (`check-tier-gate.sh`). The "do NOT ship tier N+1 until tierN_gate_passed" constraint is documented and loadable.

### S2. HARD CONSTRAINTS called out at plan level
`plan.yaml:74-109`: 6 hard constraints surfaced upfront (vibe-core pool, single-process Tier 1+2, tier gating, WS protocol v2 back-compat, backward compat timing, deploy idempotency). Implementers know which constraints are non-negotiable.

### S3. Pre-mortem identifies realistic failure modes
`plan.yaml:214-294`: 6 critical failure modes with likelihood/impact/mitigation. Mongo retry wedge, JWT skew, Redis hot-spotting, shard key corruption, vibe-core upgrade breakage, multi-region partition. Each has a concrete mitigation, not just "monitor."

### S4. Loadtest progression as regression anchor
10K -> 25K+50K -> 100K+200K with duration extending 60s -> 60s -> 120s. Each tier's loadtest is a separate dub config (`plan.yaml:917-919, 1550-1596, 2298-2343`). Progression is reproducible.

### S5. Feature flags for rollout/rollback
`IRCFIBER_WS_PROTOCOL_V2_ENABLED`, `IRCFIBER_BATCHED_USERSTREAM`, `IRCFIBER_STREAM_CONSUMER`, `IRCFIBER_STREAM_XREAD_REPLAY`, `IRCFIBER_DISABLE_WATCHDOG`, `IRCFIBER_MONGO_CIRCUIT_COOLDOWN_MS`. Each opt-in/opt-out with sane defaults. Rollback path is documented per flag.

### S6. irc_parity suite as continuous regression anchor
`plan.yaml:193-195`: "tests/irc_parity has 9 passing scenarios. The plan must keep all 9 green throughout Tier 1+2." Referenced in multiple ship_gates (`plan.yaml:2544, 2569`). Real guardrail, not aspirational.

### S7. Idempotency notes
- `sh.status()` check before re-shard (`plan.yaml:2079`)
- JSMIGRATE_DRY_RUN before apply (`plan.yaml:2102-2105`)
- janitor-migrate dry-run-then-apply pattern (`plan.yaml:264`)
- Tier 3 roles under deploy/roles/tier3_* preserve existing roles (`plan.yaml:99-101`)

### S8. Realistic vibe-core decision framing
Three options (Go rewrite / D-lib bump / accept limits) with cost estimates (3-4 months / 2-3 weeks / 1 day). Trade-offs spelled out. Decision documented as ADR (per `plan.yaml:2170-2175`).

### S9. Tier 3 correctly identified as the only true isolation layer
`plan.yaml:84`: "TIER 1+2 are single-process. They CANNOT isolate WS read, WS write, Mongo IO, Redis IO, span flush, and janitor on separate OS threads -- they all land on st_workerPool." Honest about scope.

### S10. Honest retrospective
`plan.yaml:2396-2450`: what_worked, what_we_wish_we_knew_earlier, future_thinking, questions_to_revisit. Acknowledges known unknowns.

### S11. Strong contract model between tasks
`plan.yaml:322-381`: 14 inter-task contracts specifying interface + format. Each handoff.do_not_reinvestigate block explicitly closes re-investigation. Handoff minimal_change field constrains scope.

### S12. Coordinated agent dispatch (parallelization block)
`plan.yaml:2473-2497`: explicit per-wave parallelism guidance. "t1-w1-t1 first, then t1-w1-t2 + t1-w1-t3 in parallel" -- implementers know when to fork.

### S13. Watchdog + health surface as early observability
`plan.yaml:748-911` (Tier 1 wave 3) adds the long-fiber watchdog + /api/health contention surface + SigNoz alert BEFORE the loadtest ships. Observability before benchmarks.

### S14. Failure drill task included
`plan.yaml:1980-2031` (t3-w10-t3) and `plan.yaml:2248-2296` (t3-w13-t1): explicit failover drills. Chaos engineering is a first-class task, not afterthought.

### S15. Concrete metric names from the start
OTel metrics named in each task: `gateway_long_running_fiber_seconds`, `mongo_circuit_state`, `gateway_health_check_errors_total`, `ws_yields_total`, `coalescedFramesTotal`, `redis_batched_lpush_events_total`. Names are the contract for downstream alerts.

---

## Summary

- **10 BLOCKING** -- decision_blockers (B1), conflict metadata (B2), infrastructure gap (B3), resource sizing (B4), capacity headroom (B5), schedule arithmetic (B6), Caddy capability (B7), Redis maxclients (B8), plan-internal contradiction (B9), baseline metrics (B10).
- **15 MAJOR** -- mostly runWorkerTask caveat (M1), test misalignments (M2, M13), conflations (M3), YAGNI (M4), per-replica state (M5), watchdog blind spots (M6), wasted-work tasks (M7), hidden couplings (M8), undefined state machines (M9), rework risk (M10), Node loadtest scale (M11), health tree confusion (M12), decision-blocker-not-resolved (M14), terminology drift (M15).
- **20 MINOR** -- mostly terminology, undefined thresholds, missing SLOs.
- **15 STRONG** -- clean tier decomposition, hard constraints surfaced, realistic pre-mortem, loadtest progression, feature flags, idempotency, honest retrospective.

**Critical path to fix before any implementation:**
1. Resolve B1 (ADRs for decision_blockers)
2. Resolve B6 (Tier 2 schedule)
3. Resolve B2 (conflicts_with metadata)
4. Resolve B9 (assumption/task contradiction)
5. Resolve B10 (baseline measurements)

**Critical path to fix before Tier 2 ships:**
6. Resolve B3, B4, B5, B7, B8 (infrastructure + sizing + tech compatibility)
7. Resolve M1-M15 (runWorkerTask caveat, test misalignments, hidden couplings)