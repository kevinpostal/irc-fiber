# IRC Fiber — Local Development Stack

Full local environment: IRC Fiber gateway + engine + ngIRCd test server,
with optional SigNoz Foundry (ClickHouse, Query Service, OTLP Ingester,
Frontend, Alertmanager) for observability. All containers run on the
`ircfiber_local` bridge (172.28.0.0/16).

> **Observability toggle:** SigNoz is **disabled by default** (~300 MB).
> Enable it only when debugging traces/metrics/logs (~4 GB).
> See [Observability toggle](#observability-toggle) below.

## Prerequisites

- **Docker Engine 24+** with compose plugin (v2.23+)
- **8 GB+ free RAM** (ClickHouse + SigNoz consume ~4 GB at idle)
- **Free ports**: 3301, 4317, 4318, 8090, 6667, 9000, 8123
- **macOS**: Colima or Docker Desktop running (ARM64 works; images are
  multi-arch)
- **Linux**: Kernel 5.15+ (for ClickHouse 24.8)

## Architecture

```
┌─────────────────────────────────────────────────────────────────────┐
│                     ircfiber_local (172.28.0.0/16)                  │
│                                                                     │
│  ┌──────────┐  ┌──────┐  ┌───────────────┐  ┌──────────────────┐  │
│  │  redis   │  │ mongo│  │signoz-        │  │signoz-           │  │
│  │:6379     │  │:27017│  │query-service  │  │frontend          │  │
│  │          │  │      │  │:8080 → host   │  │:3301 (internal)  │  │
│  └──────────┘  └──────┘  │3301           │  └──────────────────┘  │
│                          └───────┬───────┘                         │
│  ┌──────────────────┐            │            ┌──────────────┐     │
│  │signoz-clickhouse │◄───────────┘            │signoz-       │     │
│  │:9000 :8123       │                         │alertmanager  │     │
│  └──────┬───────────┘                         │:9093         │     │
│         │                                     └──────────────┘     │
│  ┌──────▼───────────┐                                              │
│  │signoz-ingester   │◄──── OTLP ──────┐                           │
│  │:4317(gRPC) :4318(HTTP)             │                           │
│  └──────────────────┘                 │                           │
│         │                             │                           │
│  ┌──────▼───────────┐        ┌────────▼────────┐                  │
│  │ircfiber-gateway  │        │ircfiber-engine  │                  │
│  │:8090 → host:8090 │        │localdev1        │                  │
│  │(HTTP/WS)         │        │                 │                  │
│  └──────────────────┘        └────────┬────────┘                  │
│                                       │                           │
│  ┌──────────────────┐        ┌────────▼────────┐                  │
│  │   fluent-bit     │        │  ircd (ngIRCd)  │                  │
│  │(docker logs→OTLP)│        │:6667 → host:6667│                  │
│  └──────────────────┘        └─────────────────┘                  │
└─────────────────────────────────────────────────────────────────────┘
```

### Container inventory

| Container | Image | Purpose | Host port |
|---|---|---|---|
| `ircfiber-redis` | redis:7-alpine | Session state, pub/sub, KV | — |
| `ircfiber-mongo` | mongo:7 | Network config, scrollback, prefs | — |
| `ircfiber-clickhouse` | clickhouse/clickhouse-server:24.8 | Analytics (OTel signals) | 9000, 8123 |
| `ircfiber-query-service` | signoz/query-service:latest | SigNoz REST API | 3301 → :8080 |
| `ircfiber-ingester` | signoz/otel-collector:latest | OTLP ingestion | 4317, 4318 |
| `ircfiber-frontend` | signoz/frontend:latest | SigNoz UI | — (via query-service) |
| `ircfiber-alertmanager` | signoz/alertmanager:latest | Alert dispatch | — |
| `ircfiber-fluent-bit` | fluent/fluent-bit:latest | Container log tailer → OTLP | — |
| `ircfiber-gateway` | irc-fiber:local (built) | HTTP/WS frontend + admin API | 8090 |
| `ircfiber-engine` | irc-fiber:local (built) | IRC protocol engine | — |
| `ircfiber-ircd` | ircd-local:latest (built) | ngIRCd test server | 6667 |
## Observability toggle

SigNoz + ClickHouse + fluent-bit consume ~3.5 GB (ClickHouse 2 GB + signoz
768 MB + postgres/keeper/ingester/bridge). The production host
(OVH 203.0.113.10, 7.7 GB RAM) cannot afford it, so observability is
**opt-in everywhere** and defaults to **off**.

### Default (no SigNoz, ~300 MB)

```bash
docker compose -f deploy/local/docker-compose.yml up -d
# or
make local-up
# or
make local-dev-up
```

Starts only `redis`, `mongo`, `ircfiber-gateway`, `ircfiber-engine`, `ircd`.
`signoz` and `fluent-bit` are not created (`profiles: [observability]`).
Gateway/engine have `IRCFIBER_OTEL_ENABLED=0` by default, so `withSpan` is a
pass-through, `recordCounter`/`recordGauge` no-op, and `flushAndSendSpans()`
returns immediately — no 10 s `stderr` spam when the collector is absent.

Verify:

```bash
docker compose -f deploy/local/docker-compose.yml ps
# ircfiber-gateway, ircfiber-engine, redis, mongo, ircd UP; signoz absent
curl -fsS http://localhost:8090/health  # → {"status":"ok"}
docker logs ircfiber-gateway 2>&1 | grep -c "otel.*export failed"  # → 0
make local-dev-smoke  # skips SigNoz checks when disabled
```

### With SigNoz (~4 GB)

```bash
IRCFIBER_OTEL_ENABLED=1 docker compose --profile observability -f deploy/local/docker-compose.yml up -d
# or
make local-up-observability
# or
make local-dev-up-observability
```

Starts all 7 containers including `signoz` + `fluent-bit`. `IRCFIBER_OTEL_ENABLED=1`
must be set in the shell so `docker-compose.yml` passes it to gateway/engine
(`IRCFIBER_OTEL_ENABLED: "${IRCFIBER_OTEL_ENABLED:-0}"`). `IRCFIBER_OTEL_ENDPOINT`
defaults to `http://signoz:4318`; override with `IRCFIBER_OTEL_ENDPOINT=http://…`
if you run a custom collector. The D code appends `/v1/traces` and `/v1/metrics`
automatically, so both `http://signoz:4318` and `http://signoz:4318/v1/traces`
work (empty endpoint → disabled even if flag is on, fail-safe).

Verify:

```bash
docker compose --profile observability -f deploy/local/docker-compose.yml ps
# signoz + fluent-bit UP
sleep 90
curl -fsS http://localhost:3301/api/v1/services | jq .
bash tests/local-dev/smoke-observability.sh  # all checks pass
```

Stop:

```bash
docker compose --profile observability -f deploy/local/docker-compose.yml down -v
# or
make local-down-clean
```

### Production

Production disables OTel by default. Enable only for short debugging windows:

```bash
IRCFIBER_OTEL_ENABLED=1 IRCFIBER_OTEL_ENDPOINT=http://ircfiber-otel-collector:4318 \
  docker compose --profile observability -f docker-compose.observability.yml up -d
# restart gateway/engine with the same env so they export
```

Without `IRCFIBER_OTEL_ENABLED=1`, the engine/gateway never attempt HTTP OTLP
exports and `journalctl` stays clean.

### Vite proxy when disabled

`frontend/vite.config.ts` proxies `VITE_SIGNOZ_URL` to SigNoz. When SigNoz is
disabled, set `VITE_SIGNOZ_URL=""` or leave it empty — the frontend shows an
empty observability state instead of error spinners. No code change needed.


## Bring-up

### 1. Start all services

```bash
docker compose -f deploy/local/docker-compose.yml up -d
```

First build may take 5-10 min (ClickHouse 24.8 + D compiler in Containerfile).
Subsequent starts are ~30 s after images are cached.

### 2. Monitor startup

```bash
# Watch health status
docker compose -f deploy/local/docker-compose.yml ps

# Tail all logs
docker compose -f deploy/local/docker-compose.yml logs -f

# Tail a single service
docker compose -f deploy/local/docker-compose.yml logs -f ircfiber-gateway
```

Recommended wait before testing:
- 30 s for ClickHouse health
- 60 s for SigNoz query-service health
- 90 s for the full gateway/engine health check chain

### 3. Access URLs

| Service | URL | Notes |
|---|---|---|
| SigNoz UI | http://localhost:3301 | Full observability (traces, logs, metrics) |
| Gateway health | http://localhost:8090/health | Returns `{"status":"ok"}` |
| Gateway admin API | http://localhost:8090/api/admin/servers | Requires session |
| Frontend (Vite dev) | http://localhost:5173 | Requires `npm run dev` in `frontend/` — proxies `/api` to :8090, `/api/v1-5` to :3301 |
| IRC test server | `irc://localhost:6667` | ngIRCd — connect via any IRC client |

### 4. Vite dev proxy

When using the frontend dev server (port 5173), Vite proxies:

| Proxy rule | Target | WS |
|---|---|---|
| `/api/v1/` through `/api/v5/` | `http://localhost:3301` (SigNoz) | no |
| `/signoz/` | `http://localhost:3301` (SigNoz) | yes |
| `/api/*` (catch-all) | `http://localhost:8090` (Gateway) | yes |

Override `VITE_SIGNOZ_URL` at run time:
```bash
VITE_SIGNOZ_URL=http://localhost:3301 npm run dev
```

## Smoke tests

### Observability stack

```bash
bash tests/local-dev/smoke-observability.sh
```

Validates five checks in sequence:

| # | Check | What it proves |
|---|---|---|
| a | Gateway health (`:8090/health` → 200) | Gateway is running |
| b | SigNoz API (`:3301/api/v1/services` → 200) | Query Service is up |
| c | OTLP query_range (`:3301/api/v5/query_range` → 200 + data) | Traces ingested |
| d | Fluent Bit container (`ircfiber-fluent-bit` → Up) | Log tailer active |
| e | OTLP HTTP endpoint (`:4318` → reachable) | Ingester listening |

Checks b and c may **skip** in the first 30-60 s (no data yet). Re-run after
waiting. Script exits 0 only when ALL checks pass (skips do not fail).

### IRC test server

```bash
# Verify ircd is accepting connections
nc -z localhost 6667 && echo "ircd UP"
```

### Gateway

```bash
curl -fsS http://localhost:8090/health
# → {"status":"ok"}
```

## Tear-down

### Stop (preserve data)

```bash
docker compose -f deploy/local/docker-compose.yml down
```

Keeps named volumes (`redis_data`, `mongo_data`, `signoz_clickhouse_data`).
Services restart with their previous state.

### Stop + wipe data

```bash
docker compose -f deploy/local/docker-compose.yml down -v
```

Removes **all** volumes. ClickHouse data, Redis append-only log, and Mongo
collections are lost. Use for a clean-slate reset.

## Troubleshooting

### Port conflicts

```bash
# Check what is using port 3301, 8090, or 6667
lsof -i :3301 -i :8090 -i :6667
```

Stop competing services or change the host-side port in
`deploy/local/docker-compose.yml`.

### ClickHouse out of memory

Override the memory limit on start:
```bash
CLICKHOUSE_MEMORY_LIMIT_GB=1 docker compose -f deploy/local/docker-compose.yml up -d
```

Default is 2 GB. Set lower on memory-constrained hosts (4 GB RAM total).

### SigNoz query-service won't start

Check ClickHouse connectivity:
```bash
docker compose -f deploy/local/docker-compose.yml exec signoz-clickhouse \
  clickhouse-client --query "SELECT 1"
```

If ClickHouse is healthy but query-service still fails, check its logs:
```bash
docker compose -f deploy/local/docker-compose.yml logs signoz-query-service
```

### Container in restart loop

```bash
# Inspect a specific container's recent logs
docker compose -f deploy/local/docker-compose.yml logs --tail=50 <service>

# Rebuild (e.g. after D code changes)
docker compose -f deploy/local/docker-compose.yml build ircfiber-gateway
docker compose -f deploy/local/docker-compose.yml up -d ircfiber-gateway
```

### Engine connects but no data in SigNoz

- Confirm `IRCFIBER_OTEL_ENDPOINT` in the engine's environment points to
  `http://signoz-ingester:4318` (shown correctly in docker-compose.yml by
  default)
- OTLP ingestion has a ~30 s window before traces appear in queries
- Use SigNoz's **Live Tail** (`/logs` explorer, enable live toggle) to see
  logs arriving in real time

### Vite proxy not working

- Verify both the Docker stack (`docker compose ps`) and Vite dev server
  (`npm run dev` in `frontend/`) are running
- Check console in the browser — proxied requests to `/api/admin/*` should
  go to `http://localhost:8090`; requests to `/api/v1/` through `/api/v5/`
  go to `http://localhost:3301`
- The SigNoz proxy rules MUST come before the catch-all `/api` rule in
  `vite.config.ts` (they do in the current config)
