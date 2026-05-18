---
name: backup-supabase
description: Daily/weekly backup of multiple Supabase projects (DB, Storage, Edge Functions, config) to Railway Object Storage or AWS S3. Use when the user wants to set up, modify, install, or troubleshoot Supabase backups; add/remove a client from the backup runner; restore a Supabase project from backup; or change retention/destination/notification settings.
---

# backup-supabase

Daily backup runner for multiple Supabase projects. Default deployment target is Railway (a service in the `%storage` project); EC2 is also supported. Backups land in an S3-compatible bucket (Railway Object Storage or AWS S3).

## What it backs up, per client, per run
- **Database** — `pg_dump -Fc` (custom format) + `pg_dump -Fp` (plain SQL, gzipped) of all schemas via the pooler URL.
- **Storage** — full mirror of all buckets via the project's S3 endpoint (rclone), tarred + gzipped.
- **Edge Functions** — source for every function (`supabase functions download`), tarred + gzipped.
- **Project config** — Auth/API/DB settings via Management API → JSON.
- **Manifest** — sizes, durations, sha256, tool versions.

Optionally GPG-encrypts each artifact (recipient set per client).

## Retention
- `daily/<YYYY-MM-DD>/` — kept **10 days**, older deleted by the script.
- `weekly/<YYYY-Www>/` — promoted from Sunday's daily via S3 server-side copy, kept **28 days**.

Retention is enforced by the script (Railway Object Storage has no lifecycle rules).

## Schedule
Cron inside the runner at **02:05 Asia/Jerusalem** (DST-correct via `supercronic` + `TZ` env var). Failure → POST to `WEBHOOK_URL` with `{client, stage, error, ts}` payload.

## Layout on disk
```
backup-supabase/
  scripts/        # backup.sh, backup_one.sh, prune.sh, promote_weekly.sh, notify.sh, discover_functions.sh
  install/        # Dockerfile + railway.json (Railway path), ec2-setup.sh (EC2 path)
  templates/      # client.env.example, destination.env.example
  n8n/            # backup-failure-alert.workflow.json
  RESTORE.md      # step-by-step restore runbook
  README.md       # operator guide (install, add client, rotate keys)
```

## When invoked
1. **Setting up the runner** — follow `README.md` § Install (Railway or EC2).
2. **Adding a client** — copy `templates/client.env.example` to `clients/<slug>.env`, fill values, redeploy/reload.
3. **Restoring** — follow `RESTORE.md`.
4. **Changing retention/destination/schedule** — edit constants at the top of `scripts/backup.sh` and `install/Dockerfile` `CRON` line; redeploy.

## Required external setup (one-time, manual)
- Railway bucket created in the `%storage` project (private; it is private by default — do not enable public access).
- Per-client Supabase S3 storage keys generated in the dashboard (Storage → S3 Connection).
- Per-client Supabase personal access token (account → Access Tokens) for `supabase` CLI + Management API.
- n8n webhook URL deployed from `n8n/backup-failure-alert.workflow.json`, set as `WEBHOOK_URL` env var on the runner.

## Things that CANNOT be backed up programmatically
The skill prints a reminder + generates `SECRETS_CHECKLIST.md` per client listing secret *names* (Supabase masks values):
- Edge function secrets
- SMTP password, OAuth provider client secrets
- Custom domain certs
