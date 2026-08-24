# DEPRECATED 2026-08-08 — Handoff removed, hard restart only

> **This document describes the removed `SCM_RIGHTS`/`exec`-based handoff.**
> It is kept for reference. All deploys now use hard restart
> (`docker restart ircfiber-engine-ovh`) — see `AGENTS.md#Engine Lifecycle`.
> Do not reintroduce handoff.

# IRC Fiber — True Zero-Disconnect Hot-Reload (exec-based) [DEPRECATED]

## Problem (historical)
- OLD engine (PID 7) — owns the IRC TCP/TLS sockets
- NEW engine (handoff child) — receives FDs via SCM_RIGHTS (plain TCP only)

For **plain TCP**, the FD transfer works perfectly: same socket survives.
For **TLS**, the FD cannot be transferred (TLS session state is in userspace
inside the OLD engine's memory), so the NEW engine must do a soft-reconnect:
open a new TCP socket, redo the TLS handshake, re-register IRC. The OLD
engine's TLS socket stays open during this window → IRC server sees two
simultaneous same-IP/nick connections → `Zod_` nick collision.

This breaks the user's expectation that `make update` is a true hot-reload:
the IRC connection stays up, no new connections, no nick collisions.

## Goal

`make update` MUST be a true zero-disconnect hot-reload:
- The IRC TCP socket survives the entire update (no `FIN`, no new SYN).
- The IRC server sees ONE continuous connection across code reloads.
- No nick collision, no QUIT, no re-registration.

## Architecture: `exec()`-based in-place reload

Replace the OLD engine process image with the NEW engine via `execve(2)`.
This is the Unix-native way to reload a process in-place:
- Same PID
- Same open file descriptors (unless `O_CLOEXEC` is set)
- Same process group, working directory, signal handlers
- Just the code + data segments are swapped

```
Step 1: User runs `make update`
        ↓
Step 2: BuildKit builds new binary → /app/irc-fiber-engine.new
        ↓
Step 3: Playbook signals OLD engine via Redis: "begin reload"
        ↓
Step 4: OLD engine:
        a. Pauses every IRC event loop (existing pauseForHandoff logic)
        b. Closes every file descriptor that should NOT survive:
           - The handoff control socket (Unix-domain)
           - The Redis subscriber socket
           - The Mongo client socket
           - All internal IPC sockets
           - The admin server listening socket
        c. Serializes its in-memory state to a checkpoint file:
           - For each IRC network: nick, caps, channels joined, msgid
             cursors, pending labels, server features, away status,
             realnames, parted channels, query buffers, etc.
        d. Calls `fcntl(fd, F_SETFD, 0)` on every IRC socket (clear
           O_CLOEXEC so the FD survives the exec)
        e. Writes the checkpoint file path to a sidecar env file
        f. Calls `execve("/app/irc-fiber-engine.new", ...)` — atomic,
           in-place replacement of the process image

Step 5: NEW engine (same PID, same FDs):
        a. Boots fresh
        b. Reads the checkpoint file → restores in-memory state
        c. For each IRC connection:
           - Adopts the existing TCP FD via AdoptedSocket
           - Establishes a FRESH TLS session on the SAME TCP socket
             (vibe.d's TLSStream supports this: create a new TLSStream
             wrapping the existing TCPConnection)
           - Skips IRC registration (the IRC server's session is
             keyed to the TCP connection, which is unchanged — same
             nick, same channels, same caps already registered)
           - Sends a CAP LS to refresh the cap list and verify the
             session is alive
        d. Reconnects to Redis, Mongo, admin server, etc.
        e. Resumes normal operation

Step 6: From the IRC server's perspective: ONE continuous TCP
        connection the entire time. No SYN, no FIN, no nick
        collision, no reconnect. Just a brief pause while the TLS
        layer is re-established (typically <100ms) and a CAP LS to
        refresh state.
```

## Why the IRC server sees one continuous connection

IRC servers track sessions by **TCP connection identity** (4-tuple of
local_addr, local_port, remote_addr, remote_port). When the OLD engine's
TCP socket is `exec()`-preserved into the NEW engine:
- TCP 4-tuple unchanged
- TLS handshake is just a re-authentication of the same TCP connection
  — the IRC server's IRC layer (above TLS) sees no event
- IRC session (nick, channels, caps) persists across the TLS handshake
  because it's tied to the TCP connection, not the TLS session

This means the IRC server will NOT send a QUIT for the OLD session, will
NOT free the nick, will NOT mark the user as disconnected. From its view,
ONE continuous connection, no blip.

## Files to modify

| File | Purpose |
|---|---|
| `source/ircfiber/engine/reload_orchestrator.d` | Add `serveExecReload()` — pauses, snapshots, calls `execve` |
| `source/ircfiber/irc/connection.d` | Add `adoptExistingSocket(fd, wasTls)` — re-creates TLSStream on existing TCP FD |
| `source/app_engine.d` | On startup, check for checkpoint file and adopt existing sockets |
| `deploy/playbooks/deploy-update.yml` | Send a new control message type (`beginExecReload`), wait for done marker |
| `source/ircfiber/engine/consumer.d` | Handle the new control message type |

## Wire protocol

Redis control message format (added new action):

```json
{"action":"beginExecReload","binary":"/app/irc-fiber-engine.new","deadlineMs":30000}
```

The OLD engine:
1. Receives the message
2. Performs the reload sequence (steps 4a–4f above)
3. After `execve`, the NEW engine is running

Done marker convention (existing):
- `/tmp/ircfiber-reload-done-<serverId>` — written by the OLD engine
  BEFORE calling execve, so the playbook can detect completion

## Failure modes

- **`execve` fails**: OLD engine resumes operation, marks reload as
  failed, sends `error` event to the gateway.
- **Checkpoint read fails**: NEW engine boots in fresh mode (loads
  networks from Mongo, makes new IRC connections). User sees a brief
  reconnect, but no orphan handoff child.
- **TLS handshake fails on adopted FD**: close that connection, reconnect
  normally. The other networks (if any) are unaffected.

## Migration

This is a strictly additive change:
- New control message type `beginExecReload` doesn't affect the existing
  handoff (`gracefulReload`).
- Existing deploy-update.yml continues to work.
- A new playbook variant (`deploy-update-exec.yml`) uses the new path.
- Once stable, deploy-update.yml switches to the exec path by default.

## Why not the connection holder (Option A)?

The connection holder is the most architecturally pure solution (full
separation of I/O from logic), but it requires:
- A new binary (ircfiber-conn-holder)
- A new container / supervisor
- IPC protocol between holder and engine
- Major refactor of the engine's I/O code

The `exec()`-based approach delivers the same user-facing behavior
(zero disconnect) with:
- One binary (the engine itself)
- No new IPC protocol
- No new container
- Minimal refactor (mostly additive)

The `exec()` approach is the pragmatic enterprise solution. The
connection holder remains a viable future option if we ever want to
support live multi-engine topologies (e.g. A/B testing).

## Tests

1. **`reload_doesnt_drop_tcp`**: Start engine, connect to mock IRC server,
   verify TCP connection is established. Trigger reload. Verify the
   SAME TCP connection survives (same remote port from server's POV).
2. **`reload_preserves_nick`**: Start engine with nick "Zod", connect to
   mock IRC. Trigger reload. Verify the nick is still registered without
   the server seeing a NICK change or QUIT.
3. **`reload_restores_state`**: Start engine, join #test channel, send
   some messages. Trigger reload. Verify after reload the engine is still
   in #test and the IRC state is intact.

These tests live in `source/ircfiber/engine/reload_test_runner.d` (similar
to the existing handoff-test runner).