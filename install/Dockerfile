# Runner image. Cron via supercronic (respects $TZ → Asia/Jerusalem, DST-correct).
FROM debian:bookworm-slim

ENV DEBIAN_FRONTEND=noninteractive \
    TZ=Asia/Jerusalem \
    BACKUP_ROOT=/opt/backup-supabase

RUN apt-get update && apt-get install -y --no-install-recommends \
      ca-certificates curl gnupg jq tar gzip tzdata lsb-release \
      awscli rclone \
    && install -d /usr/share/postgresql-common/pgdg \
    && curl -fsSLo /usr/share/postgresql-common/pgdg/apt.postgresql.org.asc \
         https://www.postgresql.org/media/keys/ACCC4CF8.asc \
    && echo "deb [signed-by=/usr/share/postgresql-common/pgdg/apt.postgresql.org.asc] https://apt.postgresql.org/pub/repos/apt bookworm-pgdg main" \
         > /etc/apt/sources.list.d/pgdg.list \
    && apt-get update && apt-get install -y --no-install-recommends postgresql-client-17 \
    && ln -fs /usr/share/zoneinfo/$TZ /etc/localtime && dpkg-reconfigure -f noninteractive tzdata \
    && rm -rf /var/lib/apt/lists/*

# Supabase CLI — pinned. Newer releases ship as a shim (`supabase`) plus a
# co-located `supabase-go` binary; extract the whole tar so the shim can find it.
ARG SUPABASE_CLI_VERSION=2.100.1
RUN ARCH=$(dpkg --print-architecture) \
    && case "$ARCH" in \
         amd64) SUPA_ARCH=amd64 ;; \
         arm64) SUPA_ARCH=arm64 ;; \
         *) echo "unsupported arch $ARCH" && exit 1 ;; \
       esac \
    && curl -fsSL "https://github.com/supabase/cli/releases/download/v${SUPABASE_CLI_VERSION}/supabase_${SUPABASE_CLI_VERSION}_linux_${SUPA_ARCH}.tar.gz" \
       | tar -xz -C /usr/local/bin \
    && chmod +x /usr/local/bin/supabase /usr/local/bin/supabase-go 2>/dev/null || true \
    && supabase --version

# supercronic
RUN ARCH=$(dpkg --print-architecture) \
    && case "$ARCH" in \
         amd64) SC_ARCH=amd64 ;; \
         arm64) SC_ARCH=arm64 ;; \
       esac \
    && curl -fsSLo /usr/local/bin/supercronic \
         "https://github.com/aptible/supercronic/releases/download/v0.2.29/supercronic-linux-${SC_ARCH}" \
    && chmod +x /usr/local/bin/supercronic

WORKDIR /opt/backup-supabase
COPY scripts ./scripts
RUN chmod +x scripts/*.sh

# 02:05 Asia/Jerusalem daily (supercronic uses $TZ)
RUN printf '5 2 * * * /opt/backup-supabase/scripts/backup.sh\n' > /etc/crontab.backup

ENTRYPOINT ["/opt/backup-supabase/scripts/entrypoint.sh"]
