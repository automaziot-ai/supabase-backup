#!/usr/bin/env bash
# Back up one Supabase client. Args: <client.env> <YYYY-MM-DD>
set -uo pipefail

CLIENT_ENV="$1"
TODAY="$2"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="${BACKUP_ROOT:-/opt/backup-supabase}"

# Source destination first (for DEST_S3_ENDPOINT), then client (its values win).
set -a; . "${ROOT_DIR}/destination.env"; . "$CLIENT_ENV"; set +a

AWS_S3_ARGS=()
[[ -n "${DEST_S3_ENDPOINT:-}" ]] && AWS_S3_ARGS+=(--endpoint-url "$DEST_S3_ENDPOINT")

: "${CLIENT_NAME:?CLIENT_NAME required}"
: "${SUPABASE_PROJECT_REF:?}" "${SUPABASE_ACCESS_TOKEN:?}" "${SUPABASE_DB_URL:?}"
# SRC_S3_* are optional — leave empty to skip the storage stage (client has no Supabase storage)

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
PREFIX="s3://${DEST_BUCKET}/${CLIENT_NAME}/daily/${TODAY}"
START="$(date -u +%s)"
declare -A SIZES DURATIONS SHA

run_stage() {
  local stage="$1"; shift
  local t0; t0="$(date -u +%s)"
  if ! "$@"; then
    "$SCRIPT_DIR/notify.sh" "$CLIENT_NAME" "$stage" "command failed: $*"
    return 1
  fi
  DURATIONS[$stage]=$(( $(date -u +%s) - t0 ))
}

upload() {
  local local_path="$1" remote_key="$2"
  local final="$local_path"
  if [[ -n "${GPG_RECIPIENT:-}" ]]; then
    gpg --batch --yes --trust-model always -r "$GPG_RECIPIENT" -o "${local_path}.gpg" -e "$local_path" || return 1
    final="${local_path}.gpg"
    remote_key="${remote_key}.gpg"
  fi
  SIZES[$remote_key]="$(stat -c%s "$final" 2>/dev/null || stat -f%z "$final")"
  SHA[$remote_key]="$(sha256sum "$final" | awk '{print $1}')"
  aws s3 cp "${AWS_S3_ARGS[@]}" "$final" "${PREFIX}/${remote_key}" --only-show-errors
}

# 1. DB dump
db_dump() {
  pg_dump --format=custom --no-owner --no-privileges --quote-all-identifiers \
    --file="$WORK/db.dump" "$SUPABASE_DB_URL" || return 1
  pg_dump --format=plain --no-owner --no-privileges --quote-all-identifiers "$SUPABASE_DB_URL" \
    | gzip -9 > "$WORK/db.sql.gz" || return 1
  upload "$WORK/db.dump"   "db/${CLIENT_NAME}-${TODAY}.dump" || return 1
  upload "$WORK/db.sql.gz" "db/${CLIENT_NAME}-${TODAY}.sql.gz" || return 1
}

# 2. Storage mirror
storage_dump() {
  mkdir -p "$WORK/storage"
  rclone --s3-provider Other --s3-endpoint "$SRC_S3_ENDPOINT" \
         --s3-access-key-id "$SRC_S3_ACCESS_KEY_ID" \
         --s3-secret-access-key "$SRC_S3_SECRET_ACCESS_KEY" \
         --s3-region "${SRC_S3_REGION:-us-east-1}" \
         sync ":s3:" "$WORK/storage" || return 1
  tar -C "$WORK" -czf "$WORK/storage.tar.gz" storage || return 1
  upload "$WORK/storage.tar.gz" "storage/${CLIENT_NAME}-${TODAY}.tar.gz"
}

# 3. Edge functions
functions_dump() {
  mkdir -p "$WORK/functions"
  local fns="$EDGE_FUNCTIONS"
  if [[ "$fns" == "AUTO" ]]; then
    fns="$("$SCRIPT_DIR/discover_functions.sh")" || return 1
  fi
  if [[ -z "$fns" ]]; then
    echo "{}" > "$WORK/functions/_no_functions.json"
  else
    pushd "$WORK/functions" >/dev/null
    IFS=',' read -ra arr <<< "$fns"
    for fn in "${arr[@]}"; do
      fn="$(echo "$fn" | xargs)"
      [[ -z "$fn" ]] && continue
      supabase functions download "$fn" --project-ref "$SUPABASE_PROJECT_REF" || { popd >/dev/null; return 1; }
    done
    # Capture secret NAMES (values are masked by Supabase) for the restore checklist
    supabase secrets list --project-ref "$SUPABASE_PROJECT_REF" > _secrets_names.txt 2>&1 || true
    popd >/dev/null
  fi
  tar -C "$WORK" -czf "$WORK/functions.tar.gz" functions || return 1
  upload "$WORK/functions.tar.gz" "functions/${CLIENT_NAME}-${TODAY}.tar.gz"
}

# 4. Project config (Management API)
config_dump() {
  local base="https://api.supabase.com/v1/projects/${SUPABASE_PROJECT_REF}"
  local h=(-H "Authorization: Bearer ${SUPABASE_ACCESS_TOKEN}" -H "Accept: application/json")
  {
    echo "{"
    echo '"auth":'      "$(curl -fsS "${h[@]}" "$base/config/auth" || echo null)"
    echo ',"postgres":' "$(curl -fsS "${h[@]}" "$base/config/database/postgres" || echo null)"
    echo ',"api":'      "$(curl -fsS "${h[@]}" "$base/postgrest" || echo null)"
    echo ',"project":'  "$(curl -fsS "${h[@]}" "$base" || echo null)"
    echo "}"
  } | jq '.' > "$WORK/config.json" || return 1
  upload "$WORK/config.json" "config/${CLIENT_NAME}-${TODAY}.json"
}

rc=0
run_stage db        db_dump        || rc=1
if [[ -n "${SRC_S3_ENDPOINT:-}" && -n "${SRC_S3_ACCESS_KEY_ID:-}" && -n "${SRC_S3_SECRET_ACCESS_KEY:-}" ]]; then
  run_stage storage   storage_dump   || rc=1
else
  echo "[skip] storage — SRC_S3_* not configured for $CLIENT_NAME"
fi
run_stage functions functions_dump || rc=1
run_stage config    config_dump    || rc=1

# Manifest (always upload, even on partial failure)
{
  echo "{"
  echo "  \"client\": \"$CLIENT_NAME\","
  echo "  \"date\": \"$TODAY\","
  echo "  \"started\": $START,"
  echo "  \"finished\": $(date -u +%s),"
  echo "  \"rc\": $rc,"
  echo "  \"tools\": {"
  echo "    \"pg_dump\": \"$(pg_dump --version | head -1)\","
  echo "    \"rclone\": \"$(rclone version | head -1)\","
  echo "    \"supabase\": \"$(supabase --version 2>/dev/null || echo unknown)\","
  echo "    \"aws\": \"$(aws --version 2>&1)\""
  echo "  },"
  echo "  \"durations\": {$(for k in "${!DURATIONS[@]}"; do printf '"%s":%s,' "$k" "${DURATIONS[$k]}"; done | sed 's/,$//')},"
  echo "  \"sizes\":     {$(for k in "${!SIZES[@]}";     do printf '"%s":%s,' "$k" "${SIZES[$k]}";     done | sed 's/,$//')},"
  echo "  \"sha256\":    {$(for k in "${!SHA[@]}";       do printf '"%s":"%s",' "$k" "${SHA[$k]}";    done | sed 's/,$//')}"
  echo "}"
} | jq '.' > "$WORK/manifest.json"
aws s3 cp "${AWS_S3_ARGS[@]}" "$WORK/manifest.json" "${PREFIX}/manifest.json" --only-show-errors || rc=1

exit "$rc"
