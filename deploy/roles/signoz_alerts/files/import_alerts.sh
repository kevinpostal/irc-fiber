#!/bin/bash
# Manual alert rule import via SigNoz API.
# Use this if `make signoz-alerts` fails on query schema mismatches.
# Edit alert_rules.json to taste, then:
#   SIGNOZ_API_URL=https://signoz.example.com SIGNOZ_JWT=$YOUR_JWT ./import_alerts.sh
set -euo pipefail

: "${SIGNOZ_API_URL:?Set SIGNOZ_API_URL (e.g. https://100.126.197.92:3003)}"
: "${SIGNOZ_JWT:?Get a JWT first: POST /api/v2/sessions/email_password}"

ALERTS_FILE="${1:-alert_rules.json}"
[ -f "$ALERTS_FILE" ] || { echo "No $ALERTS_FILE"; exit 1; }

# from_yaml_all / from_yaml equivalent via python
python3 <<PYEOF
import json, sys
data = json.load(open("$ALERTS_FILE"))
if isinstance(data, dict):
    rules = [data]
else:
    rules = data
print(f"Importing {len(rules)} rules…")
for r in rules:
    name = r.get("name", "?")
    rj = json.dumps(r)
    print(f"  • {name} …", end=" ", flush=True)
    out = subprocess_run = $(curl -sS -X POST "$SIGNOZ_API_URL/api/v1/rules" \
        -H "Authorization: Bearer $SIGNOZ_JWT" \
        -H "Content-Type: application/json" \
        -d "$rj" -w "\nHTTP %{http_code}")
    echo "$out" | head -1
PYEOF
