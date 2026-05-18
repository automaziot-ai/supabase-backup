#!/usr/bin/env bash
# Send failure alert to WEBHOOK_URL. Args: <client> <stage> <error_message>
set -uo pipefail
CLIENT="${1:-unknown}"
STAGE="${2:-unknown}"
ERR="${3:-unknown error}"
HOST="$(hostname)"
TS="$(date -u +%FT%TZ)"

[[ -z "${WEBHOOK_URL:-}" ]] && { echo "WEBHOOK_URL unset; skipping alert"; exit 0; }

payload=$(jq -nc \
  --arg client "$CLIENT" --arg stage "$STAGE" --arg error "$ERR" \
  --arg host "$HOST" --arg ts "$TS" \
  '{client:$client, stage:$stage, error:$error, host:$host, ts:$ts}')

curl -fsS -X POST -H 'Content-Type: application/json' --data "$payload" "$WEBHOOK_URL" \
  || echo "notify webhook failed"
