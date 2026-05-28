#!/usr/bin/env bash
# Container entrypoint. Reads env vars Railway/EC2 supplies, materializes the config files
# the rest of the scripts expect, then starts supercronic. Also supports a one-shot mode for
# manual smoke testing via `RUN_ONCE=1`.
set -euo pipefail

ROOT="${BACKUP_ROOT:-/opt/backup-supabase}"
mkdir -p "$ROOT/clients"

# destination.env from env vars
cat > "$ROOT/destination.env" <<EOF
DEST_KIND=${DEST_KIND:-railway}
DEST_BUCKET=${DEST_BUCKET:?DEST_BUCKET required}
DEST_S3_REGION=${DEST_S3_REGION:-us-east-1}
DEST_S3_ENDPOINT=${DEST_S3_ENDPOINT:-}
DEST_S3_ACCESS_KEY_ID=${DEST_S3_ACCESS_KEY_ID:?}
DEST_S3_SECRET_ACCESS_KEY=${DEST_S3_SECRET_ACCESS_KEY:?}
WEBHOOK_URL=${WEBHOOK_URL:-}
DAILY_RETENTION_DAYS=${DAILY_RETENTION_DAYS:-10}
WEEKLY_RETENTION_DAYS=${WEEKLY_RETENTION_DAYS:-28}
EOF
chmod 600 "$ROOT/destination.env"

# Single-client mode — write clients/<slug>.env from env vars
if [[ -n "${CLIENT_NAME:-}" ]]; then
  cat > "$ROOT/clients/${CLIENT_NAME}.env" <<EOF
CLIENT_NAME=${CLIENT_NAME}
SUPABASE_PROJECT_REF=${SUPABASE_PROJECT_REF:?}
SUPABASE_ACCESS_TOKEN=${SUPABASE_ACCESS_TOKEN:?}
SUPABASE_DB_URL=${SUPABASE_DB_URL:?}
SRC_S3_ENDPOINT=${SRC_S3_ENDPOINT:-}
SRC_S3_REGION=${SRC_S3_REGION:-}
SRC_S3_ACCESS_KEY_ID=${SRC_S3_ACCESS_KEY_ID:-}
SRC_S3_SECRET_ACCESS_KEY=${SRC_S3_SECRET_ACCESS_KEY:-}
EDGE_FUNCTIONS=${EDGE_FUNCTIONS:-AUTO}
GPG_RECIPIENT=${GPG_RECIPIENT:-}
EOF
  chmod 600 "$ROOT/clients/${CLIENT_NAME}.env"
  echo "[entrypoint] wrote clients/${CLIENT_NAME}.env"
fi

# RUN_ONCE=1 → execute backup immediately and exit (for smoke testing)
if [[ "${RUN_ONCE:-0}" == "1" ]]; then
  echo "[entrypoint] RUN_ONCE=1 — executing one backup then exiting"
  exec "$ROOT/scripts/backup.sh"
fi

CRON_SCHEDULE="${CRON_SCHEDULE:-5 2 * * *}"
printf '%s /opt/backup-supabase/scripts/backup.sh\n' "$CRON_SCHEDULE" > /etc/crontab.backup
echo "[entrypoint] starting supercronic; cron: '${CRON_SCHEDULE}' Asia/Jerusalem"
exec /usr/local/bin/supercronic -passthrough-logs /etc/crontab.backup
