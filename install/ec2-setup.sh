#!/usr/bin/env bash
# One-shot installer for Ubuntu 24.04 / Debian 12 EC2. Run as root.
set -euo pipefail

BACKUP_USER="backup"
BACKUP_ROOT="/opt/backup-supabase"

apt-get update
apt-get install -y --no-install-recommends \
  ca-certificates curl gnupg jq tar gzip tzdata cron \
  postgresql-client-16 awscli rclone

timedatectl set-timezone Asia/Jerusalem || true

# Supabase CLI
curl -fsSL https://github.com/supabase/cli/releases/latest/download/supabase_linux_amd64.tar.gz \
  | tar -xz -C /usr/local/bin supabase
chmod +x /usr/local/bin/supabase

id "$BACKUP_USER" &>/dev/null || useradd -r -m -d "$BACKUP_ROOT" -s /usr/sbin/nologin "$BACKUP_USER"
mkdir -p "$BACKUP_ROOT/clients" "$BACKUP_ROOT/scripts"
cp -r "$(dirname "$0")/../scripts/." "$BACKUP_ROOT/scripts/"
chmod +x "$BACKUP_ROOT/scripts/"*.sh
chown -R "$BACKUP_USER:$BACKUP_USER" "$BACKUP_ROOT"
chmod 700 "$BACKUP_ROOT/clients"

cat >/etc/cron.d/backup-supabase <<EOF
CRON_TZ=Asia/Jerusalem
SHELL=/bin/bash
PATH=/usr/local/bin:/usr/bin:/bin
5 2 * * * $BACKUP_USER $BACKUP_ROOT/scripts/backup.sh >> /var/log/backup-supabase.log 2>&1
EOF
chmod 644 /etc/cron.d/backup-supabase
touch /var/log/backup-supabase.log
chown "$BACKUP_USER:$BACKUP_USER" /var/log/backup-supabase.log
systemctl restart cron

echo "Done. Now:"
echo "  1. scp destination.env to $BACKUP_ROOT/destination.env (mode 600, owned by $BACKUP_USER)"
echo "  2. scp clients/<slug>.env files to $BACKUP_ROOT/clients/ (mode 600)"
echo "  3. Test: sudo -u $BACKUP_USER $BACKUP_ROOT/scripts/backup.sh"
