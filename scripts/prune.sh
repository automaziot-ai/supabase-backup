#!/usr/bin/env bash
# Prune old daily/ and weekly/ prefixes for one client.
set -uo pipefail
CLIENT_ENV="$1"
ROOT_DIR="${BACKUP_ROOT:-/opt/backup-supabase}"
set -a; . "${ROOT_DIR}/destination.env"; . "$CLIENT_ENV"; set +a

AWS_S3_ARGS=()
[[ -n "${DEST_S3_ENDPOINT:-}" ]] && AWS_S3_ARGS+=(--endpoint-url "$DEST_S3_ENDPOINT")

DAILY_KEEP="${DAILY_RETENTION_DAYS:-10}"
WEEKLY_KEEP="${WEEKLY_RETENTION_DAYS:-28}"

cutoff_daily="$(date -u -d "${DAILY_KEEP} days ago" +%F 2>/dev/null || date -u -v-${DAILY_KEEP}d +%F)"
cutoff_weekly_epoch="$(date -u -d "${WEEKLY_KEEP} days ago" +%s 2>/dev/null || date -u -v-${WEEKLY_KEEP}d +%s)"

prune_prefix() {
  local kind="$1" cmp="$2"
  aws s3 ls "${AWS_S3_ARGS[@]}" "s3://${DEST_BUCKET}/${CLIENT_NAME}/${kind}/" 2>/dev/null \
    | awk '{print $2}' | tr -d '/' | while read -r entry; do
      [[ -z "$entry" ]] && continue
      if "$cmp" "$entry"; then
        aws s3 rm "${AWS_S3_ARGS[@]}" --recursive "s3://${DEST_BUCKET}/${CLIENT_NAME}/${kind}/${entry}/" --only-show-errors
      fi
  done
}

is_old_daily()  { [[ "$1" < "$cutoff_daily" ]]; }
is_old_weekly() {
  # entry like 2026-W19 → take Monday of that ISO week
  local d
  d="$(date -u -d "$(echo "$1" | sed 's/W//')-1" +%s 2>/dev/null)" || return 1
  [[ "$d" -lt "$cutoff_weekly_epoch" ]]
}

prune_prefix daily  is_old_daily
prune_prefix weekly is_old_weekly
