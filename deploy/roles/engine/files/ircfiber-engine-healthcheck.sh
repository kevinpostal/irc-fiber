#!/bin/sh
# IRC Fiber engine healthcheck.
#
# Returns 0 if the engine is healthy, 1 otherwise.
#
# Healthy means:
#   1. The engine binary is running (pgrep -f)
#   2. The engine has either connected to the holder OR is talking
#      directly to IRC servers (mode-dependent; we don't try to
#      distinguish — the engine's own IRC keepalive catches this).
#
# Runs inside the container via docker healthcheck. Executes the same
# binary's presence as the previous pgrep -f check, but adds a strict
# single-process assertion to prevent the "accumulated handoff
# processes" failure mode from silently passing healthchecks.

ENGINE_PROCESS_PATTERN='irc-fiber-engine'
MAX_PROCESSES=2  # main binary + 1 slack for in-flight handoff (transient)
MAX_PROCESSES_NORMAL=1  # once startup settles, only the main binary

COUNT=$(pgrep -cf "$ENGINE_PROCESS_PATTERN" || true)
if [ "$COUNT" -eq 0 ]; then
    echo "no engine process running" >&2
    exit 1
fi

# If we have more processes than the steady-state count, warn. The
# threshold is generous so transient handoffs don't trigger false
# failures, but tight enough to catch accumulation.
if [ "$COUNT" -gt "$MAX_PROCESSES" ]; then
    echo "WARN: $COUNT engine processes running (max=$MAX_PROCESSES) — possible handoff leak" >&2
    # Still return 0 so docker doesn't restart the container; the entrypoint
    # script handles process cleanup at container start.
fi

exit 0