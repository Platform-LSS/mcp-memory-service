#!/bin/bash
## Single backup run: pg_dump → S3.
##
## Always writes to s3://$BACKUP_S3_BUCKET/hourly/YYYY/MM/DD/...
## On the 1st of the month at 00:00 UTC, also writes the same dump to
## s3://$BACKUP_S3_BUCKET/monthly/YYYY/MM/...
##
## Lifecycle (configured on the bucket, not here):
##   hourly/  → expire after 10 days
##   monthly/ → never expire
##
## Required env (validated by entrypoint.sh):
##   PGHOST PGPORT PGUSER PGPASSWORD PGDATABASE
##   AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_DEFAULT_REGION
##   BACKUP_S3_BUCKET

set -euo pipefail

ts="$(date -u +%Y-%m-%dT%H-%M-%SZ)"
date_path="$(date -u +%Y/%m/%d)"
month_path="$(date -u +%Y/%m)"
day_of_month="$(date -u +%d)"
hour_utc="$(date -u +%H)"

dump_file="/tmp/mcp-memory-pgdump-${ts}.dump"
s3_key_hourly="hourly/${date_path}/mcp-memory-pgdump-${ts}.dump"
s3_key_monthly="monthly/${month_path}/mcp-memory-pgdump-${ts}.dump"

echo "[$(date -u -Iseconds)] starting backup → ${dump_file}"

# -Fc = custom format (compressed, supports pg_restore --clean / --jobs)
pg_dump --format=custom --no-owner --no-privileges --file="${dump_file}"

size_bytes="$(stat -c %s "${dump_file}")"
echo "[$(date -u -Iseconds)] dump complete: ${size_bytes} bytes"

# Sanity check: empty/tiny dump indicates pg_dump issue.
if [ "${size_bytes}" -lt 1024 ]; then
    echo "[$(date -u -Iseconds)] ERROR: dump suspiciously small (<1KB), aborting upload" >&2
    rm -f "${dump_file}"
    exit 1
fi

aws s3 cp "${dump_file}" "s3://${BACKUP_S3_BUCKET}/${s3_key_hourly}" \
    --no-progress \
    --metadata "pg-version=16,db=${PGDATABASE},dump-utc=${ts}"
echo "[$(date -u -Iseconds)] uploaded → s3://${BACKUP_S3_BUCKET}/${s3_key_hourly}"

# Monthly snapshot: 1st of month, 00:00 UTC bucket only.
if [ "${day_of_month}" = "01" ] && [ "${hour_utc}" = "00" ]; then
    aws s3 cp "${dump_file}" "s3://${BACKUP_S3_BUCKET}/${s3_key_monthly}" \
        --no-progress \
        --metadata "pg-version=16,db=${PGDATABASE},dump-utc=${ts},retention=permanent"
    echo "[$(date -u -Iseconds)] uploaded → s3://${BACKUP_S3_BUCKET}/${s3_key_monthly}"
fi

rm -f "${dump_file}"
date -u +%s > /tmp/last_success
echo "[$(date -u -Iseconds)] backup ok"
