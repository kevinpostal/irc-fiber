# IRC Fiber — Observability Stack Runbook

Production observability built on **SigNoz** + **OpenTelemetry Collector (bridge)** + **Caddy** access log shipping + **IRC Fiber D-side OTel exporter**. **Styled in New Relic fashion** — entity model, golden signals dashboards, Apdex-style scoring. All deployed via Ansible on the OVH host (`ircfiber-ovh-1`).

## 0. New Relic-style design principles

We follow the [New Relic entity model](https://docs.newrelic.com/docs/new-relic-one/use-new-relic-one/core-concepts/what-entity-new-relic) so the UI feels familiar:

| New Relic concept | Our mapping |
|---|---|
| **Entity** (service / host / container) | Every signal carries `entity.type` ∈ {`application`, `host`, `container`} |
| **Entity name** (display) | `service.display_name` — "IRC Fiber Gateway" (not "ircfiber-gateway") |
| **Service name** (technical) | `service.name` — "ircfiber-gateway" |
| **Entity GUID** (stable) | `<service.namespace>:<service.name>` |
| **Entity tags** | `service.namespace`, `deployment.environment`, `entity.type` |
| **Golden signals** (latency, traffic, errors, saturation) | First dashboard row, Apdex-style scoring |
| **USE method** (utilization, saturation, errors) | Infrastructure dashboard |
| **NRQL-like query builder** | SigNoz's built-in query builder, with our pre-staged filters |
| **Tags** | Consistent OTel semantic conventions: `service.namespace`, `deployment.environment`, `http.*`, `db.*`, `net.*` |

## 1. Architecture

```
┌──────────────────────────────────────────────────────────────────────┐
│  OVH host (203.0.113.10, 7.7 GB RAM, Tailscale 198.51.100.1)     │
│                                                                      │
│  ircfiber_net (bridge)                ircfiber_logging (sigNoz)      │
│  ┌──────────────────┐                ┌─────────────────────────┐   │
│  │ ircfiber-caddy   │                │  signoz-signoz :8080     │   │
│  │ ircfiber-gateway │                │  signoz-clickhouse :9000 │   │
│  │ ircfiber-engine  │                │  signoz-postgres   :5432 │   │
│  │ ircfiber-holder  │                │  signoz-keeper    :2181 │   │
│  └──────────────────┘                │  signoz-ingester  :4317 │   │
│           ▲                          └─────────────────────────┘   │
│           │ OTLP traces (D-side)                  ▲                 │
│           │ /v1/traces (POST)                     │ OTLP gRPC        │
│           ▼                                       │                 │
│  ┌──────────────────────────────────────────────────────────────┐  │
│  │  ircfiber-otel-collector  (this role)                          │  │
│  │  ┌────────────────┐  ┌──────────────┐  ┌────────────────────┐  │  │
│  │  │ otlp  :4317/18 │  │ hostmetrics  │  │ filelog/containers │  │  │
│  │  │  receivers     │  │ docker_stats │  │                    │  │  │
│  │  └────────────────┘  └──────────────┘  └────────────────────┘  │  │
│  │         ↓ processors (memory_limiter, batch, transform/newrelic│  │
│  │         ↓   redaction, resourcedetection)                      │  │
│  │         ↓ export → signoz-ingester:4317 (gRPC OTLP)           │  │
│  └──────────────────────────────────────────────────────────────┘  │
│                                                                      │
│  ircfiber-caddy also exposes 100.126.197.92:3003 → signoz UI        │
│  AND ircfiber.com/signoz/* → signoz UI (with SIGNOZ-API-KEY)        │
│  Caddy access log: /var/lib/docker/volumes/ircfiber_caddy_data/...  │
└──────────────────────────────────────────────────────────────────────┘
```

## 2. Components & Health

| Container | Image | Mem | Purpose |
|---|---|---|---|
| `signoz-signoz` | `signoz/signoz:latest` | 768m | SigNoz query server + UI/API on `:8080` |
| `signoz-clickhouse` | `clickhouse/clickhouse-server:25.5.6` | 2g | Telemetry storage (logs, traces, metrics) |
| `signoz-postgres` | `postgres:16` | 256m | SigNoz user/alert metadata |
| `signoz-keeper` | `clickhouse/clickhouse-keeper:25.5.6` | 256m | ClickHouse replication coordination |
| `signoz-ingester` | `signoz/signoz-otel-collector:latest` | 256m | Internal SigNoz OTel collector |
| `ircfiber-otel-collector` | `otel/opentelemetry-collector-contrib:0.119.0` | 256m | **Bridge** — receives from D services, normalizes to NR entity model, forwards to ingester |
| `ircfiber-caddy` | caddy | — | Reverse proxy + access log source |
| `ircfiber-gateway` | `irc-fiber` (D) | — | D-side OTel trace exporter (built into `source/ircfiber/tracing.d`) |
| `ircfiber-engine-ovh` | `irc-fiber-engine` (D) | — | Heartbeat-driven OTel span export |

### Entity inventory (what shows up in SigNoz)

After deploying the bridge with the NR transform, every service has both a `service.name` (technical) and `service.display_name` (human). The SigNoz "Services" page will show:

| service.name (technical) | service.display_name (shown) | entity.type |
|---|---|---|
| `ircfiber-gateway` | IRC Fiber Gateway | application |
| `ircfiber-engine` | IRC Fiber Engine | application |
| `ircfiber-holder` | IRC Fiber Holder | application |
| `caddy` | Caddy Reverse Proxy | application |
| `docker` | IRC Fiber Docker | container |
| `signoz-signoz` | SigNoz Backend | application |
| `signoz-clickhouse` | ClickHouse Storage | application |
| `ircfiber-otel-collector` | OTel Bridge Collector | application |
| (host metrics) | OVH host 203.0.113.10 | host |
## 3. Dashboards (the New Relic feel)

Three pre-built dashboards deployed via `playbooks/signoz_dashboards.yml`:

### 3.1 `IRC Fiber — Overview` (landing page)
17 panels. The first thing you see. Mirrors New Relic's "APM overview" feel:
- **Top stats row** (the 4 stat tiles): Active services, Error rate, Caddy requests, **Apdex** (computed)
- **Golden signals row**: p50/p95/p99 latency, throughput by status, error rate, container CPU saturation
- **OVH host row**: CPU, memory, disk
- **Recent activity row**: errors list, traces list

### 3.2 `IRC Fiber — Infrastructure`
13 panels. NR-style USE method (Utilization, Saturation, Errors) for the OVH host + all containers.
- **Top tiles**: CPU%, Memory%, Disk%, Container count — with NR threshold colors (green/yellow/red at 70/85/90)
- **Host details**: CPU by state, memory by state, network I/O per device, disk I/O, filesystem usage per mount
- **Container grid**: top 20 containers by CPU with image

### 3.3 `IRC Fiber — Services Inventory`
2 panels. One row per service with count. Mirror of New Relic's "APM → Entities" list.

### 3.4 Deploy dashboards
```bash
# From the OVH host (via SSH)
ansible-playbook -l ircfiber-ovh-1 --vault-password-file .vault_pass.txt \
  playbooks/signoz_dashboards.yml -e 'vault_signoz_admin_password=YOUR_PASSWORD'

# Or push directly from your laptop via the Tailscale API endpoint
JWT=$(curl -sS -X POST http://100.126.197.92:3003/api/v2/sessions/email_password \
  -H "Content-Type: application/json" \
  -d '{"email":"kevindpostal@gmail.com","password":"...","orgId":"019f1235-79b1-787f-b4a9-370824295f2f"}' \
  | python3 -c "import sys, json; print(json.load(sys.stdin)['data']['accessToken'])")

for f in deploy/roles/signoz_dashboards/files/*.json; do
  curl -sS -X POST http://100.126.197.92:3003/api/v1/dashboards \
    -H "Authorization: Bearer $JWT" -H "Content-Type: application/json" \
    -d @$f -w "  → HTTP %{http_code}\n"
done
```

## 4. Saved views (your "favorite" queries)

SigNoz v0.130's saved views API is not externally accessible (it's a UI-only feature). Create them manually in the UI by clicking the **☆ Save View** button in any explorer. Here's the NR-style saved view recipe to recreate:

| View | Filter | Use case |
|---|---|---|
| `Slowest endpoints (24h)` | `service.name = caddy` + group by `url.path` + p95 of `http.server.request.duration` | NR "Slowest components" |
| `Top error routes` | `service.name = caddy AND http.response.status_code >= 500` + group by `url.path` | NR "Top errors" |
| `Caddy 4xx spike` | `service.name = caddy AND http.response.status_code BETWEEN 400 AND 499` | NR "Error rate" |
| `ircfiber-engine heartbeat failures` | `service.name = ircfiber-engine AND severity_text = ERROR` | NR "Service error" |
| `Container OOMKills` | `body CONTAINS 'OOMKilled'` | NR "Infra alerts" |
| `Caddy 5xx by host` | `service.name = caddy AND http.response.status_code >= 500` + group by `net.peer.ip` | NR "Errors by client" |
| `Slow traces (1h)` | `service.name != nil` + group by `name` + p95 of `durationNano` | NR "Slowest transactions" |

## 5. The bridge collector's New Relic transform

The bridge collector's `transform/newrelic` processor applies this to every signal:

```yaml
# Friendly service names (the human-readable ones)
- set(resource.attributes["service.display_name"], "IRC Fiber Gateway") where resource.attributes["service.name"] == "ircfiber-gateway"
- set(resource.attributes["service.display_name"], "IRC Fiber Engine")  where resource.attributes["service.name"] == "ircfiber-engine"
- set(resource.attributes["service.display_name"], "IRC Fiber Holder")  where resource.attributes["service.name"] == "ircfiber-holder"
- set(resource.attributes["service.display_name"], "Caddy Reverse Proxy") where resource.attributes["service.name"] == "caddy"

# Entity type classification (NR does this via tags too)
- set(resource.attributes["entity.type"], "application") where resource.attributes["service.name"] != nil
- set(resource.attributes["entity.type"], "host")        where resource.attributes["host.name"] != nil
- set(resource.attributes["entity.type"], "container")    where resource.attributes["container.name"] != nil

# Universal tags (every New Relic signal has these)
- set(resource.attributes["deployment.environment"], "production")
- set(resource.attributes["service.namespace"], "ircfiber")
```

So every query, alert, or dashboard can use either `service.name` (technical) or `service.display_name` (human).

## 6. NR-style queries you can build in the UI

### Apdex (Application Performance Index)
NR's signature single-number "user satisfaction" score:
```
apdex = (satisfied + 0.5 * tolerating) / total
       = (requests with duration < T + 0.5 * (requests with duration < 4T)) / total_requests
```
Where T is the response time threshold (0.5s default in NR). We pre-staged this in the "Apdex" panel of the Overview dashboard.

### p50/p95/p99 latency
- Group by `service.name`
- Aggregate: `p50`, `p95`, `p99` of `http.server.request.duration`

### Error rate
- Numerator: `service.name = caddy AND http.response.status_code >= 400`
- Denominator: `service.name = caddy`
- Formula: `(A / B) * 100`

### Throughput (requests per minute by status)
- Filter: `service.name = caddy`
- Group by: `http.response.status_code`
- Aggregate: `count`

### Host saturation
- `container.cpu.percent` filtered by `container.name = ircfiber-caddy`
- Or `system.cpu.utilization` for the whole OVH host

## 7. Deployment

### Full deploy (one-shot)

```bash
cd /Users/zodiac/Library/Mobile\ Documents/com~apple~CloudDocs/Work/IRC/IRC_FIBER
cd deploy

# 1. SigNoz backend (the logging role also deploys ClickHouse +
#    otel-collector-ingester + Grafana, all in one stack)
ansible-playbook -l ircfiber-ovh-1 --vault-password-file .vault_pass.txt playbooks/logging.yml

# 2. OTel bridge collector (with New Relic entity model)
ansible-playbook -l ircfiber-ovh-1 --vault-password-file .vault_pass.txt playbooks/signoz_bridge.yml

# 3. New Relic-style dashboards
ansible-playbook -l ircfiber-ovh-1 --vault-password-file .vault_pass.txt playbooks/signoz_dashboards.yml \
  -e 'vault_signoz_admin_password=YOUR_SIGNOZ_PASSWORD'

# 4. Alert rules + default notification channel
ansible-playbook -l ircfiber-ovh-1 --vault-password-file .vault_pass.txt playbooks/signoz_alerts.yml \
  -e 'vault_signoz_admin_password=YOUR_SIGNOZ_PASSWORD' \
  -e 'signoz_alert_webhook_default=https://hooks.slack.com/services/...'

# 5. Admin → SigNoz logs integration
#    Provisions the EDITOR service-account API key that Caddy injects
#    on /signoz/* requests. Without this, ircfiber.com/admin#/logs is blank.
ansible-playbook -l ircfiber-ovh-1 --vault-password-file .vault_pass.txt playbooks/signoz_mcp.yml \
  -e 'vault_signoz_admin_password=YOUR_SIGNOZ_PASSWORD'

# 6. Re-run the site role so Caddy renders the /signoz route with
#    SIGNOZ_API_KEY wired up.
ansible-playbook -l ircfiber-ovh-1 --vault-password-file .vault_pass.txt playbooks/site.yml --tags caddy
```

## 8. Verification

```bash
# 1. Bridge health
ssh deploy@203.0.113.10 'docker logs ircfiber-otel-collector | grep "Everything is ready"'

# 2. D-side OTel — check the D binary is exporting
ssh deploy@203.0.113.10 'docker exec signoz-clickhouse clickhouse-client -q "SELECT count() FROM signoz_traces.distributed_signoz_spans"'

# 3. Host metrics flowing
ssh deploy@203.0.113.10 'docker exec signoz-clickhouse clickhouse-client -q "SELECT count() FROM signoz_metrics.time_series_v4 WHERE metric_name = \"system.cpu.utilization\""'

# 4. New Relic entity model in action
# In SigNoz UI: Services page → click any service → "Entity type" filter works
# Or via API:
curl -sS http://100.126.197.92:3003/api/v1/services -H "Authorization: Bearer $JWT" | jq '.data | .[].data'

# 5. Admin logs integration (ircfiber.com/admin#/logs → SigNoz)
# Hit the public reverse-proxy and confirm the EDITOR key is being
# injected. Should return JSON with the "IRC Fiber" service inventory.
curl -fsS https://ircfiber.com/signoz/api/v1/services -H 'X-Requested-With: smoke' | head
```

Then in the SigNoz UI (http://100.126.197.92:3003/dashboards):
- Open **IRC Fiber — Overview** (the landing page)
- See golden signals + Apdex + OVH host status
- Click into any service to see its details

## 9. Other sections (unchanged from earlier)

- [Retention](#10-retention) — TTL via `SIGNOZ_DEFAULT_*_RETENTION_DAYS`
- [Alerting](#11-alerting) — pre-built rules + manual import via curl
- [PII redaction](#12-pii-redaction) — `redaction` processor in bridge config
- [Troubleshooting](#13-troubleshooting) — common issues
- [Capacity planning](#14-capacity-planning)
- [Key file locations](#15-key-file-locations-deploy)
- [Quick reference](#16-quick-reference--get-answers-fast)

## 10. Retention

Set via env on `signoz-signoz`:
```
SIGNOZ_DEFAULT_LOG_RETENTION_DAYS=7
SIGNOZ_DEFAULT_TRACES_RETENTION_DAYS=7
SIGNOZ_DEFAULT_METRICS_RETENTION_DAYS=30
```

SigNoz writes each row's TTL into the `_retention_days` column. ClickHouse drops parts when the column TTL expires (`ttl_only_drop_parts = 1` for efficiency).

## 11. Alerting

The `signoz_alerts` role ships 7 pre-built NR-style rules:

| Alert | Severity | NR-equivalent |
|---|---|---|
| `host_cpu_high` | warning | NR Infrastructure "High CPU" |
| `host_memory_high` | critical | NR "OOMKill risk" |
| `host_disk_high` | warning | NR "Low disk space" |
| `container_oom_killed` | critical | NR "Container killed by OOM" |
| `service_restart_storm` | warning | NR "Crash loop" |
| `signoz_clickhouse_down` | critical | NR "Backend down" |
| `caddy_5xx_rate` | warning | NR "Error budget burn" |

The labels `severity`, `service`, and `deployment_environment` are all NR-style and pre-attach to every alert, making it easy to route by severity in your notification webhook.

## 12. PII redaction

The bridge collector's `redaction` processor scrubs these from log bodies and attribute values:

```
password=…   passwd=…   secret=…   token=…   api_key=…   apikey=…
Authorization: Bearer …
@<provider>.com for: gmail, yahoo, hotmail, outlook, icloud, protonmail
```

Edit `/etc/ircfiber/signoz-bridge/otel-collector-config.yaml` `processors.redaction.blocked_values` to add more patterns, then:

```bash
ssh deploy@203.0.113.10 'docker restart ircfiber-otel-collector'
```

## 13. Troubleshooting

### "Why is SigNoz showing no data?"
1. `docker ps | grep otel-collector` — should be `Up` not `Restarting`
2. `curl http://100.126.197.92:3003/api/v1/user -H "Authorization: Bearer <jwt>"` — should 200
3. `docker logs signoz-clickhouse 2>&1 | tail -20` — any errors?
4. `docker logs ircfiber-otel-collector 2>&1 | tail -30` — bridge health
5. Check the bridge is on both networks: `docker inspect ircfiber-otel-collector | jq '.NetworkSettings.Networks'`

### "ClickHouse is restarting again"
1. Check the OOMKilled flag: `docker inspect signoz-clickhouse | jq '.State.OOMKilled'`
2. The 2 GB limit may be too low for your workload — bump in `roles/signoz/defaults/main.yml` (`signoz_clickhouse_mem`)
3. Check disk: `df -h /` — ClickHouse data dir is on the root volume
4. Check retention: lower `SIGNOZ_DEFAULT_LOG_RETENTION_DAYS` if disk pressure

### "Gateway traces aren't appearing"
The gateway (`app.d`) does **not** call `configureTracing()` — only the engine does (`app_engine.d:55`). The D gateway binary was built without traces. To add gateway tracing:
1. Add `import ircfiber.tracing : withSpan, flushAndSendSpans, Span, configureTracing, startTracingExporter;` to `source/app.d`
2. Add `configureTracing("http://ircfiber-otel-collector:4318/v1/traces", "ircfiber-gateway", "0.3.0")` in `app.d` startup
3. Add `flushAndSendSpans()` to a periodic task (e.g., gateway's HTTP request hook)
4. Rebuild via `make update` (BuildKit on remote)

### "Bridge can't reach signoz-ingester"
- Both must be on `ircfiber_logging` network
- Bridge has `ircfiber_logging` IP (e.g. `172.16.1.x`)
- Test: `docker exec ircfiber-otel-collector nslookup signoz-ingester` — must resolve

### "Tailscale DNS doesn't resolve ircfiber.com"
The Mac's resolver is set to Tailscale MagicDNS (`100.100.100.100`). For public domains, Tailscale forwards to upstream — but it may not always. Workarounds:
1. **Use the Tailscale hostname:** `https://ircfiber-ovh-1.tail544547.ts.net/`
2. **Or in Tailscale admin console:** DNS → Add global nameserver `1.1.1.1`

## 14. Capacity planning

| Resource | Current | Notes |
|---|---|---|
| Host RAM | 7.7 GB | 6.1 GB available |
| signoz-clickhouse | 2 GB | hard cap. Crashes if breached. |
| signoz-signoz | 768 MB | SigNoz server, query handling |
| ircfiber-otel-collector | 256 MB | hostmetrics + docker_stats + filelog |
| signoz-postgres + signoz-keeper + signoz-ingester | 256 MB each | metadata only |

## 15. Key file locations (deploy)

```
deploy/
├── roles/
│   ├── signoz/                 # SigNoz backend
│   ├── signoz_bridge/          # OTel bridge collector (with New Relic transform)
│   ├── signoz_alerts/          # Alert rules + channels
│   └── signoz_dashboards/      # NEW — pre-built NR-style dashboard JSONs
│       ├── tasks/main.yml
│       ├── defaults/main.yml
│       └── files/
│           ├── 01_overview.json
│           ├── 02_infrastructure.json
│           └── 03_services.json
├── playbooks/
│   ├── signoz_bridge.yml       # bridge deploy
│   ├── signoz_dashboards.yml   # NEW — dashboard deploy
│   ├── signoz_mcp.yml          # service-account API key
│   └── signoz_alerts.yml       # alerts deploy
└── inventories/production/hosts.ini   # ircfiber-ovh-1 host config
```

## 16. Quick reference — get answers fast

```bash
# What services are exporting?
JWT=$(curl -sS -X POST http://100.126.197.92:3003/api/v2/sessions/email_password \
  -H "Content-Type: application/json" \
  -d '{"email":"kevindpostal@gmail.com","password":"YOUR_SIGNOZ_PASSWORD","orgId":"019f1235-79b1-787f-b4a9-370824295f2f"}' \
  | python3 -c "import sys, json; print(json.load(sys.stdin)['data']['accessToken'])")
curl -sS http://100.126.197.92:3003/api/v1/services -H "Authorization: Bearer $JWT" | jq '.data[]'

# Top error routes in last hour
ssh deploy@203.0.113.10 'docker exec signoz-clickhouse clickhouse-client -q "SELECT attributes_string[\"url.path\"] AS path, count() FROM signoz_logs.logs_v2 WHERE severity_text = '\''ERROR'\'' AND timestamp > now() - 3600 GROUP BY path ORDER BY count() DESC LIMIT 10"'

# Bridge health
ssh deploy@203.0.113.10 'docker inspect ircfiber-otel-collector | jq "{Status: .State.Status, OOMKilled: .State.OOMKilled, Memory: .HostConfig.Memory, Restarts: .RestartCount}"'
```

