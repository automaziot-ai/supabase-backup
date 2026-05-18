#!/usr/bin/env bash
# Print comma-separated edge function slugs for SUPABASE_PROJECT_REF using the Management API.
set -euo pipefail
: "${SUPABASE_PROJECT_REF:?}" "${SUPABASE_ACCESS_TOKEN:?}"
curl -fsS \
  -H "Authorization: Bearer ${SUPABASE_ACCESS_TOKEN}" \
  -H "Accept: application/json" \
  "https://api.supabase.com/v1/projects/${SUPABASE_PROJECT_REF}/functions" \
  | jq -r '[.[].slug] | join(",")'
