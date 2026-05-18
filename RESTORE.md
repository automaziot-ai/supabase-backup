# Restoring a Supabase project from backup

This restores the four artifact types produced by `backup-supabase`. Total time for a medium project: 30–90 min.

## 0. Prep
- Pick the backup date you want. List the prefix to confirm artifacts exist:
  ```
  aws s3 ls --endpoint-url "$DEST_S3_ENDPOINT" \
    "s3://$DEST_BUCKET/<client>/daily/<YYYY-MM-DD>/"
  ```
- Download everything to a working dir:
  ```
  mkdir restore && cd restore
  aws s3 cp --recursive --endpoint-url "$DEST_S3_ENDPOINT" \
    "s3://$DEST_BUCKET/<client>/daily/<YYYY-MM-DD>/" .
  ```
- If artifacts end in `.gpg`, decrypt:
  ```
  for f in $(find . -name '*.gpg'); do gpg -d -o "${f%.gpg}" "$f"; done
  ```
- Verify `manifest.json` `rc == 0` and sha256 matches `sha256sum *`.

## 1. Create new Supabase project
- Dashboard → New project. Capture the new `PROJECT_REF` and DB password.
- New pooler URL: Settings → Database → Connection string (Transaction pooler).

## 2. Restore database
The dump includes `auth`, `storage`, custom schemas, RLS policies, functions, triggers.

```
pg_restore \
  --clean --if-exists \
  --no-owner --no-privileges \
  --dbname "$NEW_DB_URL" \
  db/<client>-<date>.dump
```

If `pg_restore` complains about extensions, install them first in Supabase (Database → Extensions) then re-run.

Spot-check: `psql "$NEW_DB_URL" -c "select count(*) from auth.users;"`

## 3. Restore storage
1. In new project: Storage → S3 Connection → New access key. Save them.
2. Extract and sync:
   ```
   tar -xzf storage/<client>-<date>.tar.gz
   rclone --s3-provider Other \
          --s3-endpoint "https://<NEW_REF>.supabase.co/storage/v1/s3" \
          --s3-access-key-id "$NEW_SRC_KEY" \
          --s3-secret-access-key "$NEW_SRC_SECRET" \
          --s3-region eu-central-1 \
          sync ./storage ":s3:"
   ```
Bucket definitions (public/private, size limits) were restored by pg_restore via the `storage` schema. Verify in dashboard.

## 4. Restore edge functions
```
tar -xzf functions/<client>-<date>.tar.gz
cd functions
for dir in */; do
  fn="${dir%/}"
  [[ "$fn" == "_no_functions" ]] && continue
  supabase functions deploy "$fn" --project-ref "$NEW_REF"
done
```

## 5. Re-enter secrets (NOT in backup)
Open `functions/_secrets_names.txt` for the list of secret names that existed. Re-enter values from your password manager:
```
supabase secrets set --project-ref "$NEW_REF" KEY=value KEY2=value2
```

## 6. Apply project config
Open `config/<client>-<date>.json`. The Management API re-applies auth + api cleanly. Two filters are required (verified 2026-05-15 against a fresh test project):

- **Drop `null` values** — PATCH endpoints reject `null` for fields like `db_pool`.
- **Drop paid-tier-only fields** if restoring to a lower plan — Free tier 402s on Pro features. Strip with the regex below.

```bash
TOKEN=$NEW_PERSONAL_ACCESS_TOKEN

# Auth — strip nulls + paid-tier-only fields
jq '.auth
  | with_entries(select(
      (.key | test("hook_password_verification|hook_mfa_verification|^oauth_server_|^api_max_|^db_max_|^db_min_|^rate_limit_") | not)
      and .value != null))' config/<client>-<date>.json \
  | curl -sS -X PATCH "https://api.supabase.com/v1/projects/$NEW_REF/config/auth" \
      -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" --data @-

# API (PostgREST) — strip nulls
jq '.api | with_entries(select(.value != null))' config/<client>-<date>.json \
  | curl -sS -X PATCH "https://api.supabase.com/v1/projects/$NEW_REF/postgrest" \
      -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" --data @-
```

**Skip `.postgres` and `.project`** — those are platform-level settings (instance size, region, project name) that don't meaningfully transfer between projects.

**SMTP password and OAuth client secrets DO come across** in the config dump (Management API returns them in plain text). That's convenient for restore — you don't need to re-enter them. But it also means **`config.json` contains sensitive secrets in plaintext** — set `GPG_RECIPIENT` on the client to encrypt every artifact at rest if this matters.

## 7. Smoke test
- Log in as an existing user (password reset if needed)
- Read/write one row in a `public` table
- Open one storage file
- Invoke one edge function
- Check RLS still blocks anon where expected
