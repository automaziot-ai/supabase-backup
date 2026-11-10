#!/usr/bin/env bash
# Send failure alert to WEBHOOK_URL. Args: <client> <stage> <error_message>
# Always exits 0: a broken/missing webhook must never change a backup's result.
# The alert text is also written to the log so it is visible even when delivery fails.
set -uo pipefail
CLIENT="${1:-unknown}"
STAGE="${2:-unknown}"
ERR="${3:-unknown error}"
HOST="$(hostname)"
TS="$(date -u +%FT%TZ)"
NOTIFY_TIMEOUT_SECONDS=20

echo "[notify] ALERT client=${CLIENT} stage=${STAGE}: ${ERR}"

[[ -z "${WEBHOOK_URL:-}" ]] && { echo "[notify] WEBHOOK_URL unset; alert logged only"; exit 0; }

payload=$(jq -nc \
  --arg client "$CLIENT" --arg stage "$STAGE" --arg error "$ERR" \
  --arg host "$HOST" --arg ts "$TS" \
  '{client:$client, stage:$stage, error:$error, host:$host, ts:$ts}')

# No -f: read the HTTP status ourselves so the log says what happened (the URL is not
# logged — n8n webhook paths act as bearer secrets).
curl_rc=0
http_code="$(curl -sS -o /dev/null -w '%{http_code}' --max-time "$NOTIFY_TIMEOUT_SECONDS" \
  -X POST -H 'Content-Type: application/json' --data "$payload" "$WEBHOOK_URL" 2>&1)" || curl_rc=$?

if [[ "$curl_rc" -ne 0 ]]; then
  echo "[notify] WARNING: alert NOT delivered — webhook request failed (curl exit ${curl_rc}: ${http_code}). Backup result unaffected; fix WEBHOOK_URL."
elif [[ ! "$http_code" =~ ^2 ]]; then
  echo "[notify] WARNING: alert NOT delivered — webhook answered HTTP ${http_code}. Backup result unaffected; fix WEBHOOK_URL (n8n workflow inactive/deleted?)."
fi
exit 0
