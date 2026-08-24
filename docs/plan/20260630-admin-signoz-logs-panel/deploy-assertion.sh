#!/usr/bin/env bash
# IRC Fiber -- admin logs deploy assertion
# Verifies the SigNoz reverse-proxy chain (Caddy SIGNOZ_API_KEY injection
# + Vite dev proxy + /api/v1/user auth) works end-to-end. Run from any
# machine that can reach https://ircfiber.com and (optionally) the local
# Vite dev server on :5173.

set -euo pipefail

LOG="docs/plan/20260630-admin-signoz-logs-panel/deploy-assertion.log"
mkdir -p "$(dirname "$LOG")"

ts() { date -u +"%Y-%m-%dT%H:%M:%SZ"; }
say() { echo "[$(ts)] $*" | tee -a "$LOG"; }
check() {
  local name="$1"; shift
  if "$@"; then
    say "PASS  $name"
    return 0
  else
    say "FAIL  $name"
    return 1
  fi
}

# 1) Production /api/v1/services (SigNoz backend via gateway/Caddy).
# Expect 200 + JSON body that contains a "serviceName" key.
check_prod_api_v1_services() {
  local body code
  body=$(curl -sS -m 10 -w '\n%{http_code}' https://ircfiber.com/api/v1/services || true)
  code=$(printf '%s\n' "$body" | tail -1)
  body=$(printf '%s\n' "$body" | head -n -1)
  if [ "$code" = "200" ] && printf '%s' "$body" | grep -q '"serviceName"'; then
    return 0
  fi
  say "        body: $body"
  say "        code: $code"
  if [ "$code" = "404" ]; then
    say "        remediation: /signoz/* handle_path missing OR caddy_signoz_api_key env var empty in Caddyfile.j2 conditional"
  elif [ "$code" = "401" ] || [ "$code" = "403" ]; then
    say "        remediation: ircfiber-caddy missing SIGNOZ_API_KEY -- run signoz_mcp role first"
  else
    say "        remediation: VITE_SIGNOZ_URL unset OR ircfiber-caddy missing SIGNOZ_API_KEY OR /signoz/* handle_path missing"
  fi
  return 1
}

# 2) Production /signoz/api/v1/services (Caddy reverse proxy with SIGNOZ-API-KEY header).
# Expect 200 OR 401 (auth wall from Caddy when key env is missing is a known-good state).
# NEVER 404 (404 means the /signoz/* handle_path block is absent from Caddyfile.j2).
check_prod_signoz_proxy() {
  local code
  code=$(curl -sS -m 10 -o /dev/null -w '%{http_code}' https://ircfiber.com/signoz/api/v1/services || echo "000")
  if [ "$code" = "200" ] || [ "$code" = "401" ]; then
    return 0
  fi
  say "        code: $code"
  if [ "$code" = "404" ]; then
    say "        remediation: Caddyfile.j2 /signoz/* handle_path block missing (see deploy/roles/caddy/templates/Caddyfile.j2:60-79)"
  else
    say "        remediation: VITE_SIGNOZ_URL unset OR ircfiber-caddy missing SIGNOZ_API_KEY OR /signoz/* handle_path missing"
  fi
  return 1
}

# 3) /api/v1/user responds with orgId -- validates that auth + WS URL construction work
# through the gateway, which is a prerequisite for the Logs SPA iframe.
check_api_v1_user_orgid() {
  local body code orgid
  body=$(curl -sS -m 10 -w '\n%{http_code}' https://ircfiber.com/api/v1/user || true)
  code=$(printf '%s\n' "$body" | tail -1)
  body=$(printf '%s\n' "$body" | head -n -1)
  if [ "$code" = "200" ] && printf '%s' "$body" | grep -q '"orgId"'; then
    orgid=$(printf '%s' "$body" | grep -oE '"orgId":"[^"]+"' | head -1 || true)
    say "        detected: $orgid"
    return 0
  fi
  say "        body: $body"
  say "        code: $code"
  say "        remediation: gateway auth failure -- check session cookie and upstream 401 propagation"
  return 1
}

# 4) Vite dev proxy routes /api/v1..5/* and /signoz/*.
# Prerequisites: `npm run dev` (or `npm run dev:host`) is running locally on :5173.
# Expect 200 (SigNoz reachable) OR 502 (Vite proxy up, SigNoz down/missing).
# NEVER 404 (404 means the dev-proxy rule in vite.config.ts is missing).
check_vite_dev_proxy() {
  local code
  code=$(curl -sS -m 10 -o /dev/null -w '%{http_code}' http://localhost:5173/api/v1/services || echo "000")
  if [ "$code" = "200" ] || [ "$code" = "502" ]; then
    return 0
  fi
  say "        code: $code"
  if [ "$code" = "000" ]; then
    say "        remediation: Vite dev server not running -- start with 'npm run dev' on :5173"
  else
    say "        remediation: VITE_SIGNOZ_URL unset (default http://127.0.0.1:8080) OR dev proxy rules missing (see frontend/vite.config.ts)"
  fi
  return 1
}

# main
say "=== IRC Fiber admin-logs deploy assertion ==="
fail=0
check "prod /api/v1/services"  check_prod_api_v1_services || fail=$((fail+1))
check "prod /signoz/* proxy"   check_prod_signoz_proxy    || fail=$((fail+1))
check "/api/v1/user has orgId" check_api_v1_user_orgid    || fail=$((fail+1))
check "vite dev proxy"         check_vite_dev_proxy       || fail=$((fail+1))

if [ "$fail" -eq 0 ]; then
  say "=== ALL PASS ==="
  exit 0
else
  say "=== $fail check(s) FAILED ==="
  exit 1
fi
