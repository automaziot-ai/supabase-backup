# backup-supabase — operator guide

Daily Supabase backups (DB + Storage + Edge Functions + project config) per client, running on Railway (default) or EC2, written to a Railway Object Storage bucket (Tigris) or AWS S3, retained 10 daily + 4 weekly. Failure → n8n webhook → Telegram group.

## Layout in the bucket
```
s3://<DEST_BUCKET>/<client>/
  daily/YYYY-MM-DD/
    db/<client>-YYYY-MM-DD.dump          (pg_dump -Fc)
    db/<client>-YYYY-MM-DD.sql.gz        (pg_dump -Fp gzipped)
    storage/<client>-YYYY-MM-DD.tar.gz   (rclone mirror — only if SRC_S3_* set)
    functions/<client>-YYYY-MM-DD.tar.gz (supabase functions download + secret names)
    config/<client>-YYYY-MM-DD.json      (Management API: auth/api/postgres/project)
    manifest.json                        (rc, sizes, durations, sha256, tool versions)
  weekly/YYYY-Www/                       (Sunday copy of daily/, kept 28 days)
```
Files end in `.gpg` if `GPG_RECIPIENT` is set for the client.

## Cutting Supabase egress (opt-in)
Every nightly run reads the whole project from Supabase: two `pg_dump` passes (custom +
plain) and every Storage object. On a free-plan project (5 GB egress/month) that alone
can exhaust the quota. All knobs below are **per client and off by default** — a client
that sets none of them gets exactly the historical backup.

| Variable | Effect | Egress saved |
|---|---|---|
| `PG_DUMP_SINGLE_PASS=1` | `db.sql.gz` is rendered locally from `db.dump` with `pg_restore` instead of a second `pg_dump`. Same SQL; only cosmetic quoting of a couple of `SET`/`CREATE SCHEMA` lines differs. | ~50% of DB egress |
| `PG_DUMP_EXCLUDE_TABLE_DATA=<p1>,<p2>` | Each pattern becomes one `--exclude-table-data=<p>` argument (no shell quoting involved; `*` wildcards; `schema.*` = whole schema; quote mixed-case names `public."MyTable"`). Table definitions, indexes and policies are still dumped — only rows are skipped. | rows of those tables |
| `FULL_DUMP_WEEKDAY=1..7` | On that ISO weekday (Asia/Jerusalem; 7 = Sunday = the run promoted to `weekly/`) the exclusions are ignored. | — |
| `STORAGE_MODE=incremental` | Storage is copied remote→remote (`rclone copy --size-only`) into a persistent mirror at the destination. Unchanged objects are skipped using listing data only (no per-object HEAD/GET against Supabase). The daily folder gets an object listing instead of a tarball. | all unchanged objects |
| `STORAGE_HISTORY_RETENTION_DAYS` | Days to keep superseded object versions (default `WEEKLY_RETENTION_DAYS`). | — |
| `DEST_PREFLIGHT=1` | Writes `<client>/_preflight.txt` first; if the destination rejects it (e.g. rotated bucket keys → `SignatureDoesNotMatch`) the client is skipped before any Supabase read. | the whole run, when the destination is broken |

Manifests of clients that use any of these get an extra `options` object (`storage_mode`,
`db_dump: full|partial`, `db_excluded_table_data`, `pg_dump_single_pass`).

Incremental storage layout:
```
<client>/storage-mirror/current/<bucket>/<key>          latest copy of every object ever seen (never deleted)
<client>/storage-mirror/history/<date>/<bucket>/<key>   version replaced on <date> (pruned after STORAGE_HISTORY_RETENTION_DAYS)
<client>/daily/<date>/storage/<client>-<date>.objects.json   which objects (path + size) existed that night
```
Why `--size-only`: rclone's default modtime comparison issues a HEAD per object on both
sides (S3 modtime lives in metadata), and `--checksum` trusts that both providers' ETags
are MD5s. Size needs only the listings. Trade-off: an object overwritten in place with
content of the exact same byte size is not re-copied — acceptable for upload-once
assets; don't use incremental mode for buckets that rewrite same-size files in place.
If the destination needs virtual-hosted-style URLs, set
`RCLONE_CONFIG_BKDEST_FORCE_PATH_STYLE=false` on the service.

Caveats: excluded tables restore empty — if other tables have foreign keys *into* them,
`pg_restore` will report those constraints as failed until the data is re-created. The
first incremental run downloads everything once to seed the mirror. `STORAGE_MODE=incremental`
is ignored (full mode used) when `GPG_RECIPIENT` is set, since the mirror is not encrypted.

## Schedule
`02:05 Asia/Jerusalem` daily (supercronic inside the container honors `$TZ` for DST). Sunday's run is also copied (server-side `aws s3 cp --recursive`) to `weekly/`. Both retention windows are enforced by `prune.sh` after every run (Railway/Tigris buckets have no native lifecycle rules).

## Deployment model — per-client runner

One runner service per client, inside that client's own Railway project. The runner reads its config from **Railway environment variables** (not from mounted files). On container start, `scripts/entrypoint.sh` materializes those env vars into `/opt/backup-supabase/destination.env` and `/opt/backup-supabase/clients/<slug>.env`, then starts supercronic. This means **once env vars are set on the Railway service, you never re-paste them** — they persist across deployments, Railway is the source of truth.

## Install — Railway (canonical flow, tested on PG-Backup-Itzhak)

### 1. Create the destination bucket (one-time, dashboard)
- Open the client's Railway project → **+ New → Database → Bucket** (or "Object Storage").
- Bucket is **private by default** — leave it private.
- From the bucket → **Connect** tab, copy: `BUCKET_NAME`, endpoint host, access key id, secret access key.
  - Use the dashboard "copy" buttons, not select-and-copy by hand. Tigris secrets contain hyphens and are easy to truncate. (Got bitten by this in setup #1.)

### 2. Link the skill folder to that project
```
cd ~/.claude/skills/backup-supabase
railway login            # one-time, browser flow
railway link --project <PROJECT_ID> --environment production
```
`PROJECT_ID` from the dashboard URL or `railway status --json`.

### 3. Create the runner service with all env vars
```
railway add \
  --service supabase-backup-runner \
  --variables "DEST_KIND=railway" \
  --variables "DEST_BUCKET=<bucket-name>" \
  --variables "DEST_S3_REGION=auto" \
  --variables "DEST_S3_ENDPOINT=https://t3.storageapi.dev" \
  --variables "DEST_S3_ACCESS_KEY_ID=tid_..." \
  --variables "DEST_S3_SECRET_ACCESS_KEY=tsec_..." \
  --variables "WEBHOOK_URL=https://eyaly555.app.n8n.cloud/webhook/supabase-backup-failed" \
  --variables "CLIENT_NAME=<slug>" \
  --variables "SUPABASE_PROJECT_REF=..." \
  --variables "SUPABASE_ACCESS_TOKEN=sbp_..." \
  --variables "SUPABASE_DB_URL=postgresql://postgres.<ref>:<pwd>@aws-1-<region>.pooler.supabase.com:5432/postgres" \
  --variables "EDGE_FUNCTIONS=AUTO" \
  --variables "RUN_ONCE=1"
```
- `DEST_S3_REGION=auto` for Railway/Tigris buckets. AWS S3 → use the real region (e.g. `eu-central-1`).
- `RUN_ONCE=1` makes the first deploy execute the backup immediately and exit — that's the smoke test.
- Storage stage auto-skips when `SRC_S3_*` are unset (clients without Supabase storage).

### 4. Link to the new service and deploy
```
railway service supabase-backup-runner
railway up --detach
```
Build takes ~2 min (installs PG17 client from PGDG repo, supabase CLI, rclone, awscli, supercronic).

### 5. Watch the smoke test
```
railway logs                        # tail container output
# Expected: "[entrypoint] RUN_ONCE=1 ..." → DB dump → functions download → uploads → exit
```
Then verify objects landed:
```
AWS_ACCESS_KEY_ID=tid_... AWS_SECRET_ACCESS_KEY=tsec_... AWS_DEFAULT_REGION=auto \
  aws s3 ls --endpoint-url https://t3.storageapi.dev \
  s3://<bucket>/<client>/daily/$(date +%F)/ --recursive
```
You should see 4–5 files + manifest.json. Pull manifest → `rc` must be `0`.

### 6. Flip into normal cron mode
```
railway variables --service supabase-backup-runner --set "RUN_ONCE=0"
railway redeploy --service supabase-backup-runner --yes
```
Container now sits idle in supercronic, fires at 02:05 ILS each day.

## Install — EC2

```
sudo bash install/ec2-setup.sh
sudo scp destination.env       ec2:/opt/backup-supabase/destination.env
sudo scp clients/<slug>.env    ec2:/opt/backup-supabase/clients/
sudo chown backup:backup /opt/backup-supabase/{destination.env,clients/*}
sudo chmod 600 /opt/backup-supabase/{destination.env,clients/*}
sudo -u backup /opt/backup-supabase/scripts/backup.sh     # smoke test
```
For AWS S3, prefer an IAM instance role over keys in `destination.env`.

## Where credentials live (the canonical answer)

**Source of truth = Railway env vars on the service**. Once set with `railway add --variables` (step 3 above), they persist forever — redeploys, restarts, image rebuilds all keep them. You never re-paste them.

For your own records, also store them in a **password manager** (1Password, Bitwarden), one entry per client, containing:
- Supabase project ref
- Supabase personal access token
- Supabase DB password
- Bucket name + endpoint + access key + secret
- Webhook URL
- (Optional) GPG recipient

This is your fallback if the Railway service is deleted by accident or if a key rotates. **Never paste them into chat (Slack, Telegram, Claude conversations) — chat history is not a secrets store.**

## Adding another client
Repeat steps 1–6 above against that client's Railway project. Each runner is self-contained; no cross-client state.

## Updating the runner code after the skill changes
```
cd ~/.claude/skills/backup-supabase
railway link --project <client-project-id> --environment production
railway service supabase-backup-runner
railway up --detach
```
Env vars are untouched — only the image changes.

## Operational checks
- Daily: scan the Telegram alert group. **No alert = success.**
- Weekly: `aws s3 ls ...` confirm `daily/YYYY-MM-DD/manifest.json` exists for every client.
- Quarterly: pick a random backup → run `RESTORE.md` against a throwaway Supabase project. A backup you have never restored is not a backup.

## Pitfalls (already debugged in setup #1)
| Symptom | Cause | Fix |
|---|---|---|
| `pg_dump: aborting because of server version mismatch` | Debian's `postgresql-client` is v15; Supabase runs v17 | Install `postgresql-client-17` from PGDG repo (already in Dockerfile) |
| `InvalidAccessKeyId` after rotating via dashboard "Regenerate" | **The dashboard button is broken — it updates Railway's display but doesn't rotate Tigris** | **NEVER use the dashboard regenerate.** Rotate ONLY via `railway bucket credentials --reset --bucket <name>`. Read current keys via `railway bucket credentials --bucket <name> --json`. Set as static env vars on the service (`DEST_S3_ACCESS_KEY_ID`, `DEST_S3_SECRET_ACCESS_KEY`). |
| `${{<bucket>.ACCESS_KEY_ID}}` references serve old values | Reference variables don't refresh on rotation | Use static values from CLI output, not references |
| `pg_restore: errors ignored on restore: 634` (or similar) | Supabase-internal event triggers owned by `supabase_admin` | Ignore. Verify success by row counts (`auth.users`, public tables, RLS policies). |
| Upload URL becomes `*.s3.auto.amazonaws.com` | `--endpoint-url` flag lost in subprocess (bash arrays don't export) | Each script that calls `aws` sources `destination.env` and rebuilds the flag (done) |
| `InvalidAccessKeyId` after redeploy / "creds in container don't match Railway env" | `destination.env` is written ONCE at container start; later env-var changes don't reach disk | After `railway variables --set ...`, also `railway redeploy --yes` to refresh in-container files |
| Run exits 1, log shows `SignatureDoesNotMatch` on every upload | Destination bucket keys rotated/invalid — the run still downloads everything from Supabase, then fails every upload | Refresh `DEST_S3_*` (see ONBOARDING § Rotating bucket creds) and redeploy; set `DEST_PREFLIGHT=1` so a broken destination costs no Supabase egress |
| `[notify] WARNING: alert NOT delivered — webhook answered HTTP 404` | n8n workflow behind `WEBHOOK_URL` is inactive/deleted. Alerts are lost but the backup result is unaffected (notify always exits 0) | Re-activate/redeploy the n8n workflow or fix `WEBHOOK_URL` |
| Telegram spam loop | Container exits non-zero, Railway restart policy kicks in | While debugging set `WEBHOOK_URL=muted-during-debug` (curl 404s silently, no alert) |

## What is NOT backed up (must record manually)
- Edge function secret **values** (Supabase masks them). Names are captured in `functions/_secrets_names.txt`.
- SMTP password, third-party OAuth client secrets.
- Custom domain TLS config.
Keep these in the per-client password-manager entry.

## Restoring
See `RESTORE.md`.

## n8n failure alert
1. Import `n8n/backup-failure-alert.workflow.json` into n8n.
2. Activate workflow → production webhook URL is set on the runner as `WEBHOOK_URL`.
3. Set `ALERT_TARGET_URL` in n8n (Telegram bot sendMessage URL, Slack incoming webhook, etc.).

Payload sent by `notify.sh`:
```json
{ "client": "acme", "stage": "db", "error": "...", "host": "runner-1", "ts": "2026-05-14T23:05:12Z" }
```

## Tested deployments
- **Itzhak** (project `PG-Backup-Itzhak`, project id `2bfb0081-27d2-47ea-b223-194bd2c7b59f`) — service `supabase-backup-runner`, bucket `foldable-pouch-halohj4bbp`. First successful backup: 2026-05-14, rc=0, 123s, 5 edge functions, no Supabase storage.
