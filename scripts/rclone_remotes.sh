#!/usr/bin/env bash
# Sourced helper (not executed). Defines `rclone_bk`, which runs rclone with two
# named remotes configured purely from environment variables (no rclone.conf,
# no secrets on the command line):
#   bksrc:   the client's Supabase Storage S3 endpoint  (SRC_S3_*)
#   bkdest:  the backup destination bucket's endpoint   (DEST_S3_*)
# Only the remote(s) whose credentials are present are defined.
#
# Escape hatch: any rclone option can still be overridden from the environment,
# e.g. RCLONE_CONFIG_BKDEST_FORCE_PATH_STYLE=false for a destination that only
# accepts virtual-hosted-style URLs (rclone defaults to path style for "Other").

rclone_bk() (
  # Subshell: the exports below never leak into the caller, and secrets are
  # passed via the environment (export is a builtin), never via argv.
  local -a envs=()
  if [[ -n "${SRC_S3_ENDPOINT:-}" && -n "${SRC_S3_ACCESS_KEY_ID:-}" ]]; then
    envs+=(
      RCLONE_CONFIG_BKSRC_TYPE=s3
      RCLONE_CONFIG_BKSRC_PROVIDER=Other
      "RCLONE_CONFIG_BKSRC_ENDPOINT=${SRC_S3_ENDPOINT}"
      "RCLONE_CONFIG_BKSRC_ACCESS_KEY_ID=${SRC_S3_ACCESS_KEY_ID}"
      "RCLONE_CONFIG_BKSRC_SECRET_ACCESS_KEY=${SRC_S3_SECRET_ACCESS_KEY:-}"
      "RCLONE_CONFIG_BKSRC_REGION=${SRC_S3_REGION:-us-east-1}"
    )
  fi
  if [[ -n "${DEST_S3_ACCESS_KEY_ID:-}" ]]; then
    local dest_provider=Other
    [[ -z "${DEST_S3_ENDPOINT:-}" ]] && dest_provider=AWS
    envs+=(
      RCLONE_CONFIG_BKDEST_TYPE=s3
      "RCLONE_CONFIG_BKDEST_PROVIDER=${dest_provider}"
      "RCLONE_CONFIG_BKDEST_ENDPOINT=${DEST_S3_ENDPOINT:-}"
      "RCLONE_CONFIG_BKDEST_ACCESS_KEY_ID=${DEST_S3_ACCESS_KEY_ID}"
      "RCLONE_CONFIG_BKDEST_SECRET_ACCESS_KEY=${DEST_S3_SECRET_ACCESS_KEY:-}"
      "RCLONE_CONFIG_BKDEST_REGION=${DEST_S3_REGION:-us-east-1}"
      # The bucket already exists; restricted keys may not be allowed to create/probe it.
      RCLONE_CONFIG_BKDEST_NO_CHECK_BUCKET=true
    )
  fi
  [[ ${#envs[@]} -gt 0 ]] && export "${envs[@]}"
  exec rclone "$@"
)
