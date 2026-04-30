#!/bin/bash
## Runs backup.sh every 4 hours on UTC clock boundaries (00, 04, 08, 12, 16, 20).
## A failed run is logged but does not crash the container — the next cycle
## tries again. The healthcheck in the Dockerfile reports unhealthy if no
## successful run in 5h.

set -uo pipefail

required_vars=(
    PGHOST PGPORT PGUSER PGPASSWORD PGDATABASE
    AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_DEFAULT_REGION
    BACKUP_S3_BUCKET
)
missing=0
for var in "${required_vars[@]}"; do
    if [ -z "${!var:-}" ]; then
        echo "ERROR: required env var ${var} is unset" >&2
        missing=1
    fi
done
[ "${missing}" -eq 1 ] && exit 1

interval=14400  # 4h in seconds

# Sleep until the next 4h boundary (00, 04, 08, 12, 16, 20 UTC), then loop.
sleep_until_next_boundary() {
    local now_epoch next_boundary
    now_epoch="$(date -u +%s)"
    next_boundary=$(( (now_epoch / interval + 1) * interval ))
    local delta=$(( next_boundary - now_epoch ))
    echo "[$(date -u -Iseconds)] sleeping ${delta}s until next 4h boundary"
    sleep "${delta}"
}

echo "[$(date -u -Iseconds)] mcp-memory-backup starting; bucket=${BACKUP_S3_BUCKET} db=${PGDATABASE}@${PGHOST}"

# Run once on startup so we don't wait up to 4h for first proof-of-life.
if /opt/backup/backup.sh; then
    echo "[$(date -u -Iseconds)] startup backup ok"
else
    echo "[$(date -u -Iseconds)] startup backup FAILED (will retry on schedule)" >&2
fi

while true; do
    sleep_until_next_boundary
    if /opt/backup/backup.sh; then
        :
    else
        echo "[$(date -u -Iseconds)] scheduled backup FAILED (will retry next cycle)" >&2
    fi
done
