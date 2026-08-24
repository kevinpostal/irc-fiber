#!/bin/sh
# IRC Fiber engine entrypoint.
#
# Ensures clean container state on every restart:
#   1. Kill any leftover irc-fiber-engine processes (defensive — Docker
#      should never leave them, but we've seen 3+ accumulate from
#      accumulated graceful handoff invocations).
#   2. Remove stale handoff socket / done markers from prior runs.
#   3. exec the engine binary directly (replaces the shell so signals
#      reach the engine process and tini reports correct PID).
#
# This script is built into the engine image at /usr/local/bin and is
# the container's ENTRYPOINT in deploy/roles/engine/tasks/main.yml.

set -eu

ENGINE_BIN=/app/irc-fiber-engine

log() { printf '[engine-entrypoint] %s\n' "$*" >&2; }

# ── 1. Kill stale engine processes ───────────────────────────────────────
# pkill -f matches the full cmdline, which covers both the live binary
# (`/app/irc-fiber-engine`) and any temp paths used by graceful handoff
# (`/tmp/irc-fiber-engine.<pid>.<ts>`). -x avoids matching tini itself.
STALE=$(pgrep -f irc-fiber-engine || true)
if [ -n "$STALE" ]; then
    log "Killing stale engine processes: $STALE"
    # shellcheck disable=SC2086
    kill $STALE 2>/dev/null || true
    # Give them 5s to exit gracefully, then SIGKILL stragglers.
    sleep 2
    REMAINING=$(pgrep -f irc-fiber-engine || true)
    if [ -n "$REMAINING" ]; then
        log "Force-killing stubborn processes: $REMAINING"
        # shellcheck disable=SC2086
        kill -9 $REMAINING 2>/dev/null || true
        sleep 1
    fi
fi

# ── 2. Remove stale handoff markers ─────────────────────────────────────
# Successful handoff writes a done marker. Failed handoffs leave a
# stale socket. Both must be cleaned up so the next deploy doesn't
# short-circuit on a stale state.
rm -f /tmp/ircfiber-handoff-*.sock \
      /tmp/ircfiber-handoff-done-* \
      /tmp/ircfiber-engine-handoff-child.log || true

# ── 3. Exec the engine ─────────────────────────────────────────────────
# `exec` replaces the shell so the engine becomes PID 1's child via
# tini — signals (SIGTERM/SIGINT) reach the engine cleanly, and the
# container's main PID matches the engine PID. This is critical for
# healthchecks and graceful shutdown.
log "Starting irc-fiber-engine ($ENGINE_BIN)"
exec "$ENGINE_BIN" "$@"