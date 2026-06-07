#!/usr/bin/env bash
# Entry point. Loops every clients/*.env and runs backup_one.sh, then promotes weekly + prunes.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="${BACKUP_ROOT:-/opt/backup-supabase}"
CLIENTS_DIR="${ROOT_DIR}/clients"
DEST_ENV="${ROOT_DIR}/destination.env"

[[ -f "$DEST_ENV" ]] || { echo "missing $DEST_ENV"; exit 2; }
# shellcheck disable=SC1090
set -a; . "$DEST_ENV"; set +a

export AWS_ACCESS_KEY_ID="$DEST_S3_ACCESS_KEY_ID"
export AWS_SECRET_ACCESS_KEY="$DEST_S3_SECRET_ACCESS_KEY"
export AWS_DEFAULT_REGION="$DEST_S3_REGION"
export AWS_REGION="$DEST_S3_REGION"
[[ -n "${DEST_S3_ENDPOINT:-}" ]] && export AWS_ENDPOINT_URL="$DEST_S3_ENDPOINT" AWS_ENDPOINT_URL_S3="$DEST_S3_ENDPOINT"
export AWS_REQUEST_CHECKSUM_CALCULATION=WHEN_REQUIRED
export AWS_RESPONSE_CHECKSUM_VALIDATION=WHEN_REQUIRED
AWS_S3_ARGS=()

TODAY="$(TZ=Asia/Jerusalem date +%F)"
DOW="$(TZ=Asia/Jerusalem date +%u)"   # 1..7, 7 = Sunday
HOUR="$(TZ=Asia/Jerusalem date +%H)"
WEEK="$(TZ=Asia/Jerusalem date +%G-W%V)"

# Multi-run-per-day support: when BACKUP_INCLUDE_HOUR=1, append -HH to the date
# so runs at 06/12/18 don't overwrite each other. Single-cron clients leave this unset.
if [[ "${BACKUP_INCLUDE_HOUR:-0}" == "1" ]]; then
  TODAY="${TODAY}-$(TZ=Asia/Jerusalem date +%H)"
fi

shopt -s nullglob
clients=("$CLIENTS_DIR"/*.env)
[[ ${#clients[@]} -gt 0 ]] || { echo "no clients in $CLIENTS_DIR"; exit 2; }

overall_rc=0
for client_env in "${clients[@]}"; do
  if ! "$SCRIPT_DIR/backup_one.sh" "$client_env" "$TODAY"; then
    overall_rc=1
  fi

  # Promote to weekly on Sunday. Tigris LIST is eventually consistent right after
  # backup_one.sh's PUTs, so we don't precheck — just attempt the cp. An empty source
  # is a no-op success; real failures (auth, network) trip the notify.
  # Multi-run-per-day clients (BACKUP_INCLUDE_HOUR=1) pin WEEKLY_PROMOTE_HOUR so only
  # one of the day's runs is promoted; single-run clients leave it unset.
  if [[ "$DOW" == "7" && ( -z "${WEEKLY_PROMOTE_HOUR:-}" || "$HOUR" == "${WEEKLY_PROMOTE_HOUR}" ) ]]; then
    # shellcheck disable=SC1090
    ( set -a; . "$DEST_ENV"; . "$client_env"; set +a
      s3_args=()
      [[ -n "${DEST_S3_ENDPOINT:-}" ]] && s3_args+=(--endpoint-url "$DEST_S3_ENDPOINT")
      src="s3://${DEST_BUCKET}/${CLIENT_NAME}/daily/${TODAY}/"
      dst="s3://${DEST_BUCKET}/${CLIENT_NAME}/weekly/${WEEK}/"
      if ! err=$(aws s3 cp "${s3_args[@]}" --recursive "$src" "$dst" 2>&1); then
        "$SCRIPT_DIR/notify.sh" "$CLIENT_NAME" "weekly-promote" "copy failed: ${err}"
      fi
    )
  fi

  # Retention
  "$SCRIPT_DIR/prune.sh" "$client_env"
done

exit "$overall_rc"
