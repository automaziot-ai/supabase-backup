#!/usr/bin/env bash
# Rebuild Supabase Storage exactly as listed in one STORAGE_MODE=incremental snapshot.
#
# Usage: storage_restore.sh <objects.json> <snapshot-date> <rclone-target>
#   objects.json   daily|weekly/<date>/storage/<client>-<date>.objects.json (downloaded)
#   snapshot-date  the <date> folder it came from, e.g. 2026-11-10 (or 2026-11-10-06)
#   rclone-target  where to write: a local dir (./restored) or a remote such as `newsupa:`
#                  defined via RCLONE_CONFIG_NEWSUPA_* env vars (see RESTORE.md)
# Env: CLIENT_NAME, DEST_BUCKET, DEST_S3_ENDPOINT, DEST_S3_REGION, DEST_S3_ACCESS_KEY_ID,
#      DEST_S3_SECRET_ACCESS_KEY — the same values the runner uses.
#
# For each listed object it takes storage-mirror/current/ when the size matches, otherwise
# the earliest storage-mirror/history/<d>/ with d > snapshot-date holding that size (the
# version that was overwritten after the snapshot). Objects in the mirror but absent from
# the listing (deleted before the snapshot) are not restored. Exit 2 if any object could
# not be resolved; they are printed.
set -euo pipefail

[[ $# -eq 3 ]] || { sed -n '2,9p' "$0"; exit 64; }
LISTING="$1" SNAPSHOT="$2" TARGET="$3"
: "${CLIENT_NAME:?}" "${DEST_BUCKET:?}" "${DEST_S3_ACCESS_KEY_ID:?}" "${DEST_S3_SECRET_ACCESS_KEY:?}"
[[ -s "$LISTING" ]] || { echo "listing not found or empty: $LISTING" >&2; exit 64; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=rclone_remotes.sh
. "$SCRIPT_DIR/rclone_remotes.sh"
BASE="bkdest:${DEST_BUCKET}/${CLIENT_NAME}/storage-mirror"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

size_map() { jq 'map({key: .Path, value: .Size}) | from_entries' "$1"; }

# Objects still needed, as {path: size}.
size_map "$LISTING" > "$WORK/need.json"

# copy_matching <rclone-source-dir> <label>: copy every needed object whose size matches
# there, then drop it from need.json.
copy_matching() {
  local src="$1" label="$2"
  rclone_bk lsjson -R --files-only --no-modtime --no-mimetype "$src" > "$WORK/have.raw.json" 2>/dev/null \
    || echo '[]' > "$WORK/have.raw.json"
  size_map "$WORK/have.raw.json" > "$WORK/have.json"
  jq -r --slurpfile have "$WORK/have.json" \
    'to_entries[] | select($have[0][.key] == .value) | .key' "$WORK/need.json" > "$WORK/files.txt"
  local n; n="$(grep -c '' "$WORK/files.txt" || true)"
  echo "[restore] ${label}: ${n} object(s)"
  [[ "$n" -gt 0 ]] || return 0
  rclone_bk copy "$src" "$TARGET" --files-from-raw "$WORK/files.txt" --no-traverse \
    --stats 10m --stats-log-level NOTICE
  jq --rawfile copied "$WORK/files.txt" \
    '($copied | split("\n") | map(select(length > 0)) | map({key: ., value: true}) | from_entries) as $d
     | with_entries(select($d[.key] | not))' "$WORK/need.json" > "$WORK/need.next.json"
  mv "$WORK/need.next.json" "$WORK/need.json"
}

echo "[restore] snapshot ${SNAPSHOT}: $(jq 'length' "$WORK/need.json") object(s) listed"
copy_matching "${BASE}/current" "current"

if [[ "$(jq 'length' "$WORK/need.json")" -gt 0 ]]; then
  rclone_bk lsf --dirs-only "${BASE}/history" 2>/dev/null | tr -d '/' | sort > "$WORK/history_dirs.txt" || true
  while read -r d; do
    [[ -n "$d" && "$d" > "$SNAPSHOT" ]] || continue
    [[ "$(jq 'length' "$WORK/need.json")" -gt 0 ]] || break
    copy_matching "${BASE}/history/${d}" "history/${d}"
  done < "$WORK/history_dirs.txt"
fi

missing="$(jq 'length' "$WORK/need.json")"
if [[ "$missing" -gt 0 ]]; then
  echo "[restore] ${missing} object(s) could not be resolved (size mismatch or pruned history):" >&2
  jq -r 'keys[]' "$WORK/need.json" >&2
  exit 2
fi
echo "[restore] complete"
