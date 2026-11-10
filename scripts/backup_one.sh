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

# shellcheck source=rclone_remotes.sh
. "$SCRIPT_DIR/rclone_remotes.sh"

# --- Opt-in egress reducers. Unset = exactly the historical behaviour. -------------
# STORAGE_MODE=incremental    keep a persistent mirror at the destination; only
#                             new/changed objects are downloaded from Supabase.
# PG_DUMP_EXCLUDE_TABLE_DATA  comma-separated pg_dump --exclude-table-data patterns
#                             (schema is still dumped, only rows are skipped).
# FULL_DUMP_WEEKDAY=1..7      ISO weekday (Asia/Jerusalem, 7=Sunday) on which the
#                             exclusions are ignored and a full dump is taken.
# PG_DUMP_SINGLE_PASS=1       build db.sql.gz from db.dump locally (pg_restore)
#                             instead of a second pg_dump over the network.
# DEST_PREFLIGHT=1            check the destination is writable before reading
#                             anything from Supabase; abort the client if not.
STORAGE_MODE="${STORAGE_MODE:-full}"
PG_DUMP_EXCLUDE_TABLE_DATA="${PG_DUMP_EXCLUDE_TABLE_DATA:-}"
FULL_DUMP_WEEKDAY="${FULL_DUMP_WEEKDAY:-}"
PG_DUMP_SINGLE_PASS="${PG_DUMP_SINGLE_PASS:-0}"
DEST_PREFLIGHT="${DEST_PREFLIGHT:-0}"

log() { echo "[backup:${CLIENT_NAME}] $*"; }

case "$STORAGE_MODE" in
  full|incremental) ;;
  *) log "WARN: unknown STORAGE_MODE='${STORAGE_MODE}' — using 'full'"; STORAGE_MODE=full ;;
esac
if [[ "$STORAGE_MODE" == "incremental" && -n "${GPG_RECIPIENT:-}" ]]; then
  # The mirror stores objects as-is; it cannot honour per-artifact GPG encryption.
  log "WARN: STORAGE_MODE=incremental is not supported with GPG_RECIPIENT — using 'full'"
  STORAGE_MODE=full
fi
if [[ -n "$FULL_DUMP_WEEKDAY" && ! "$FULL_DUMP_WEEKDAY" =~ ^[1-7]$ ]]; then
  log "WARN: FULL_DUMP_WEEKDAY='${FULL_DUMP_WEEKDAY}' is not 1..7 — ignoring it"
  FULL_DUMP_WEEKDAY=""
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
PREFIX="s3://${DEST_BUCKET}/${CLIENT_NAME}/daily/${TODAY}"
START="$(date -u +%s)"
declare -A SIZES DURATIONS SHA
FAILED_STAGES=()

run_stage() {
  local stage="$1"; shift
  local t0; t0="$(date -u +%s)"
  if ! "$@"; then
    log "stage '${stage}' FAILED (command: $*)"
    FAILED_STAGES+=("$stage")
    "$SCRIPT_DIR/notify.sh" "$CLIENT_NAME" "$stage" "command failed: $*"
    return 1
  fi
  DURATIONS[$stage]=$(( $(date -u +%s) - t0 ))
}

trim() {
  local s="$1"
  s="${s#"${s%%[![:space:]]*}"}"
  printf '%s' "${s%"${s##*[![:space:]]}"}"
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

# 0. Optional destination preflight — fail before spending any source egress.
dest_preflight() {
  date -u +%FT%TZ > "$WORK/preflight.txt"
  aws s3 cp "${AWS_S3_ARGS[@]}" "$WORK/preflight.txt" \
    "s3://${DEST_BUCKET}/${CLIENT_NAME}/_preflight.txt" --only-show-errors
}

# 1. DB dump
# Fills PG_EXCLUDE_ARGS (one --exclude-table-data=PATTERN argv element per pattern, so
# no shell quoting is involved) and DB_DUMP_KIND (full|partial).
PG_EXCLUDE_ARGS=()
DB_DUMP_KIND=full
build_db_exclude_args() {
  [[ -z "$PG_DUMP_EXCLUDE_TABLE_DATA" ]] && return 0
  if [[ -n "$FULL_DUMP_WEEKDAY" && "$(TZ=Asia/Jerusalem date +%u)" == "$FULL_DUMP_WEEKDAY" ]]; then
    log "db: FULL_DUMP_WEEKDAY=${FULL_DUMP_WEEKDAY} is today — full dump, exclusions ignored"
    return 0
  fi
  local pattern
  IFS=',' read -ra patterns <<< "$PG_DUMP_EXCLUDE_TABLE_DATA"
  for pattern in "${patterns[@]}"; do
    pattern="$(trim "$pattern")"
    [[ -n "$pattern" ]] && PG_EXCLUDE_ARGS+=("--exclude-table-data=${pattern}")
  done
  [[ ${#PG_EXCLUDE_ARGS[@]} -gt 0 ]] || return 0
  DB_DUMP_KIND=partial
  log "db: partial dump — rows skipped for: ${PG_EXCLUDE_ARGS[*]#--exclude-table-data=}"
}

db_dump() {
  pg_dump --format=custom --no-owner --no-privileges --quote-all-identifiers \
    "${PG_EXCLUDE_ARGS[@]}" --file="$WORK/db.dump" "$SUPABASE_DB_URL" || return 1
  if [[ "$PG_DUMP_SINGLE_PASS" == "1" ]]; then
    # Same SQL as a plain pg_dump, rendered locally from the archive: no second download.
    pg_restore --no-owner --no-privileges --file=- "$WORK/db.dump" | gzip -9 > "$WORK/db.sql.gz" || return 1
  else
    pg_dump --format=plain --no-owner --no-privileges --quote-all-identifiers \
      "${PG_EXCLUDE_ARGS[@]}" "$SUPABASE_DB_URL" \
      | gzip -9 > "$WORK/db.sql.gz" || return 1
  fi
  upload "$WORK/db.dump"   "db/${CLIENT_NAME}-${TODAY}.dump" || return 1
  upload "$WORK/db.sql.gz" "db/${CLIENT_NAME}-${TODAY}.sql.gz" || return 1
}

# 2a. Storage, incremental: persistent mirror at the destination.
#   <client>/storage-mirror/current/<bucket>/<key>        latest copy of every object ever seen
#   <client>/storage-mirror/history/<date>/<bucket>/<key> previous version of objects that
#                                                         were overwritten on <date>
#   daily/<date>/storage/<client>-<date>.objects.json     which objects existed on <date>
# Nothing is ever deleted from current/ (copy, not sync); the daily listing defines the
# snapshot. --size-only: unchanged objects are skipped from listing data alone, with no
# per-object HEAD against Supabase and no reliance on how either provider forms ETags.
storage_incremental() {
  local mirror="bkdest:${DEST_BUCKET}/${CLIENT_NAME}/storage-mirror/current"
  local history="bkdest:${DEST_BUCKET}/${CLIENT_NAME}/storage-mirror/history/${TODAY}"
  # Listing first: anything it names is either already in the mirror or copied below.
  rclone_bk lsjson -R --files-only --no-modtime --no-mimetype "bksrc:" \
    > "$WORK/storage.objects.json" || return 1
  log "storage: $(jq 'length' "$WORK/storage.objects.json") objects, $(jq '[.[].Size] | add // 0' "$WORK/storage.objects.json") bytes at source"
  rclone_bk copy "bksrc:" "$mirror" --size-only --backup-dir "$history" \
    --stats 10m --stats-log-level NOTICE || return 1
  upload "$WORK/storage.objects.json" "storage/${CLIENT_NAME}-${TODAY}.objects.json"
}

# 2b. Storage, full (default): download everything and upload a tarball.
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
    : > _failed_functions.txt
    for fn in "${arr[@]}"; do
      fn="$(echo "$fn" | xargs)"
      [[ -z "$fn" ]] && continue
      if ! err=$(supabase functions download "$fn" --project-ref "$SUPABASE_PROJECT_REF" 2>&1); then
        echo "${fn}: ${err}" >> _failed_functions.txt
      fi
    done
    # Capture secret NAMES (values are masked by Supabase) for the restore checklist
    supabase secrets list --project-ref "$SUPABASE_PROJECT_REF" > _secrets_names.txt 2>&1 || true
    popd >/dev/null
    if [[ -s "$WORK/functions/_failed_functions.txt" ]]; then
      "$SCRIPT_DIR/notify.sh" "$CLIENT_NAME" "functions-partial" \
        "$(wc -l < "$WORK/functions/_failed_functions.txt" | tr -d ' ') function(s) failed to download; backup continues. See _failed_functions.txt in tar."
    fi
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
if [[ "$DEST_PREFLIGHT" == "1" ]] && ! run_stage preflight dest_preflight; then
  log "destination s3://${DEST_BUCKET} is not writable — skipping every stage so no Supabase egress is spent (rc=1)"
  exit 1
fi
build_db_exclude_args
run_stage db        db_dump        || rc=1
if [[ -n "${SRC_S3_ENDPOINT:-}" && -n "${SRC_S3_ACCESS_KEY_ID:-}" && -n "${SRC_S3_SECRET_ACCESS_KEY:-}" ]]; then
  if [[ "$STORAGE_MODE" == "incremental" ]]; then
    run_stage storage storage_incremental || rc=1
  else
    run_stage storage   storage_dump   || rc=1
  fi
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
# Record opt-in modes only when one is active, so default manifests are unchanged.
if [[ "$STORAGE_MODE" != "full" || "$DB_DUMP_KIND" != "full" || -n "$PG_DUMP_EXCLUDE_TABLE_DATA" || "$PG_DUMP_SINGLE_PASS" == "1" ]]; then
  jq --arg storage_mode "$STORAGE_MODE" --arg db_dump "$DB_DUMP_KIND" \
     --arg excluded "$(printf '%s\n' "${PG_EXCLUDE_ARGS[@]#--exclude-table-data=}")" \
     --arg single_pass "$PG_DUMP_SINGLE_PASS" \
     '. + {options: {storage_mode: $storage_mode, db_dump: $db_dump,
                     db_excluded_table_data: ($excluded | split("\n") | map(select(length > 0))),
                     pg_dump_single_pass: ($single_pass == "1")}}' \
     "$WORK/manifest.json" > "$WORK/manifest.opts.json" \
    && mv "$WORK/manifest.opts.json" "$WORK/manifest.json"
fi
aws s3 cp "${AWS_S3_ARGS[@]}" "$WORK/manifest.json" "${PREFIX}/manifest.json" --only-show-errors || { rc=1; FAILED_STAGES+=(manifest); }

if [[ "$rc" -eq 0 ]]; then
  log "done rc=0"
else
  log "done rc=${rc} — failed stage(s): ${FAILED_STAGES[*]:-unknown}"
fi
exit "$rc"
