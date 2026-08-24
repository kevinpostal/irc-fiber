# IRC Fiber — Split Hardening (Step 4)

> Checklist for operating the gateway/engine split after Steps 0-3. No new services; just wiring and kill-switches.

## OTel — both runtimes independently

| Service | Init | Endpoint | SigNoz service name |
|---|---|---|---|
| D gateway (`app.d:195-201`) | `configureTracing(otelTracesEp,"ircfiber-gateway","0.3.0")` + `configureMetrics` | `IRCFIBER_OTEL_ENDPOINT` (`/v1/traces` + `/v1/metrics`) → `signoz-ingester:4318` direct in dev, or `ircfiber-otel-collector` bridge in prod (`deploy/roles/signoz_bridge/templates/otel-collector-config.yaml.j2`) | `ircfiber-gateway` |
| D engine (`app_engine.d:28-65` `setupOtel("ircfiber-engine")`) | same env | same endpoint | `ircfiber-engine` |
| Python gateway (`api-python/app/main.py:34-51`) | `TracerProvider` + `BatchSpanProcessor(OTLPSpanExporter)` to `IRCFIBER_OTEL_ENDPOINT/v1/traces` when `IRCFIBER_OTEL_ENABLED=1` | same endpoint | `ircfiber-api-py` |

All three appear as distinct services in SigNoz dashboards (`deploy/roles/logging/files/dashboards/*`) without schema change. Verify: `http://…:8080/api/v1/services` lists `ircfiber-gateway`, `ircfiber-engine`, and (when enabled) `ircfiber-api-py`.

## Handoff / graceful reload

- **Engine-internal only:** `source/ircfiber/engine/handoff.d` SCM_RIGHTS + `reload_orchestrator.d` adopt + `irc/connection.d:pauseForHandoff` — no gateway involvement. See `docs/HOT_RELOAD_ARCHITECTURE.md`.
- **After split:** `deploy/playbooks/deploy-update.yml` triggers handoff **only** on `ircfiber-engine` (via `LPUSH irc:control:<serverId> gracefulReload` + `IRCFIBER_RELOAD_FROM_PID` exec). Gateway rolling updates are plain restarts (no FD transfer) — `docker restart ircfiber-gateway` or `make gateway-restart`.
- **Docs note:** keep `views/` in `runtime-engine` as empty stubs only if handoff e2e ever needs it; engine never renders templates, so current `runtime-engine` omits `views/`/`public/` (verified by `docker run … ls /app/views` → No such file).

## Kill-switch / rollback

| Command | Effect |
|---|---|
| `make gateway-restart` | Restarts gateway container only (`docker restart` or `runTask` relaunch). No IRC disconnect. |
| `make engine-handoff` | Graceful SCM_RIGHTS handoff (preserves plain TCP sockets; TLS soft-reconnect ~1s). |
| `make engine-restart` | Hard restart (closes sockets, reconnect). |
| `make api-python-up` / `make api-python-down` | Local dev: `docker compose -f deploy/local/docker-compose.yml -f deploy/local/docker-compose.override.python.yml up -d irc-fiber-api-py` (port 8001). Down tears it down. |
| `ansible-playbook playbooks/site.yml --tags gateway` | Rolls only gateway (Caddy + gateway env). |
| `ansible-playbook playbooks/site.yml --tags engine` | Rolls only engine (engine env + handoff socket). |
| Caddy flip `gateway_use_python` | `vars.yml → gateway_use_python: true` flips `Caddyfile.j2` upstream to `irc-fiber-api-py:8000`. Roll back by toggling var + `systemctl reload caddy`. No frontend rebuild needed (`API_BASE` stays `/api` behind Caddy). |

Ansible `site.yml` should expose `gateway` and `engine` tags (already via roles). If not, add `tags: [gateway]` / `[engine]` to the respective plays.

## Prod parity / observability verification

After `ansible-playbook playbooks/site.yml --tags gateway`:

```
curl -fsS https://ircfiber.com/api/health | jq '{status,mongo: .mongoVersion?, redis: .redisVersion?}'
# → {"healthy":true, ...}

# SigNoz services (via tailnet or local port-forward)
curl -fsS http://127.0.0.1:3301/api/v1/services | jq '.[] | .name'
# → ircfiber-gateway, ircfiber-engine, (ircfiber-api-py when toggled)
```

Caddy flip needs no frontend redeploy unless `VITE_API_BASE` default changes (it defaults to `/api`).

## Assumptions carried forward

- Session shape (`session:<sid>` hash, JSON-quoted values, 14-day TTL) is the stable boundary for both gateways.
- `ensureEngineHealthy` → synthetic `ERROR` `irc_event` is preserved in Python (see `docs/WS_PROTOCOL.md`).
- `systemManaged` delete guard (`rest.d:297-303`) stays in every implementation.
