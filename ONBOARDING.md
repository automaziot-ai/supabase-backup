# Onboarding a new Supabase client

Time: ~10 minutes per client, mostly Docker build wait.

## Prerequisites — collect from the client's Supabase project

1. **Project ref** — 20-char string in `https://supabase.com/dashboard/project/<REF>/`
2. **DB pooler URL with password** — Settings → Database → Connection string → **Transaction** tab. Reset password first if unknown.
3. **Personal access token** — supabase.com → Account → Access Tokens → generate `backup-runner-<client>`. Starts with `sbp_`.
4. **(Optional) Storage S3 keys** — only if client uses Supabase Storage. Storage → S3 Connection → New access key.

Plus: access to the client's Railway project.

## Steps

### 1. Create bucket in client's Railway project (dashboard)
**+ New → Database → Bucket** → name `supabase-backups-<client>`. Leave private.

> NEVER click "Regenerate" on the bucket Connect tab. It's broken — orphan creds. Use CLI only.

### 2. Link skill to client's Railway project
```bash
cd ~/.claude/skills/backup-supabase
railway link --project <CLIENT_PROJECT_ID> --environment production
```

### 3. Pull bucket creds via CLI
```bash
railway bucket list
eval "$(railway bucket credentials --bucket <bucket-name> --json | python3 -c "
import json,sys,shlex
d=json.load(sys.stdin)
for k,v in [('AKID',d['accessKeyId']),('SECRET',d['secretAccessKey']),
            ('REGION',d['region']),('BUCKET',d['bucketName']),
            ('ENDPOINT',d['endpoint'])]:
    print(f'{k}={shlex.quote(v)}')
")"
```

### 4. Create runner service with env vars
```bash
railway add \
  --service supabase-backup-runner \
  --variables "DEST_KIND=railway" \
  --variables "DEST_BUCKET=$BUCKET" \
  --variables "DEST_S3_REGION=$REGION" \
  --variables "DEST_S3_ENDPOINT=$ENDPOINT" \
  --variables "DEST_S3_ACCESS_KEY_ID=$AKID" \
  --variables "DEST_S3_SECRET_ACCESS_KEY=$SECRET" \
  --variables "WEBHOOK_URL=https://eyaly555.app.n8n.cloud/webhook/supabase-backup-failed" \
  --variables "CLIENT_NAME=<slug>" \
  --variables "SUPABASE_PROJECT_REF=<ref>" \
  --variables "SUPABASE_ACCESS_TOKEN=sbp_<...>" \
  --variables "SUPABASE_DB_URL=postgresql://postgres.<ref>:<pwd>@aws-1-<region>.pooler.supabase.com:5432/postgres" \
  --variables "EDGE_FUNCTIONS=AUTO" \
  --variables "RUN_ONCE=1"
```

If client uses Supabase Storage, add:
```bash
  --variables "SRC_S3_ENDPOINT=https://<ref>.supabase.co/storage/v1/s3" \
  --variables "SRC_S3_REGION=<region>" \
  --variables "SRC_S3_ACCESS_KEY_ID=..." \
  --variables "SRC_S3_SECRET_ACCESS_KEY=..."
```

### 5. Deploy
```bash
railway service supabase-backup-runner
railway up --detach
```

### 6. Watch smoke test
```bash
railway logs --service supabase-backup-runner
```
Should see: `RUN_ONCE=1 — executing one backup then exiting` → stages → exit clean.

Verify in bucket:
```bash
AWS_ACCESS_KEY_ID="$AKID" AWS_SECRET_ACCESS_KEY="$SECRET" AWS_DEFAULT_REGION="$REGION" \
  aws s3 cp --endpoint-url "$ENDPOINT" \
  "s3://$BUCKET/<slug>/daily/$(date +%F)/manifest.json" - | jq .rc
```
Must be `0`.

### 7. Flip to cron mode
```bash
railway variables --service supabase-backup-runner --set "RUN_ONCE=0"
railway redeploy --service supabase-backup-runner --yes
```
Now fires daily at 02:05 Asia/Jerusalem. Sunday → weekly promotion. Retention auto-enforced.

### 8. Record creds in password manager
One entry per client. Source of truth is Railway, but keep an offline copy.

## Updating runner code across all clients
```bash
cd ~/.claude/skills/backup-supabase
for proj in <id1> <id2> <id3>; do
  railway link --project "$proj" --environment production
  railway service supabase-backup-runner
  railway up --detach
done
```
Env vars persist; only image rebuilds.

## Rotating bucket creds (when needed)
```bash
railway bucket credentials --reset --bucket <name> --yes
eval "$(railway bucket credentials --bucket <name> --json | python3 -c "...")"  # as in step 3
railway variables --service supabase-backup-runner \
  --set "DEST_S3_ACCESS_KEY_ID=$AKID" \
  --set "DEST_S3_SECRET_ACCESS_KEY=$SECRET"
railway redeploy --service supabase-backup-runner --yes   # MUST redeploy — destination.env on disk only refreshes on container start
```
