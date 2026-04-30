#!/usr/bin/env bash
## Restore the mcp-memory pgvector database from an S3 backup.
##
## Usage:
##   scripts/team/restore_from_s3.sh                       # interactive picker
##   scripts/team/restore_from_s3.sh s3://bucket/key.dump  # specific backup
##   scripts/team/restore_from_s3.sh --list                # just list backups
##
## Uses YOUR aws credentials (from `aws configure` or AWS_* env vars), NOT
## the IAM user baked into tools/docker/.env. The container's IAM user is
## intentionally write-only and cannot read backups.
##
## Requirements on the host:
##   - aws cli configured with read access to the backup bucket
##   - docker (mcp-memory-postgres + mcp-memory-service running)
##
## Process:
##   1. Show plan, require explicit y/N confirmation
##   2. Download dump to /tmp
##   3. Stop mcp-memory-service (so it doesn't write during restore)
##   4. pg_restore --clean --if-exists into mcp-memory-postgres
##   5. Restart mcp-memory-service, wait for healthy
##   6. Print row counts for sanity

set -euo pipefail

SERVICE_CONTAINER="mcp-memory-service"
POSTGRES_CONTAINER="mcp-memory-postgres"
PG_USER="mcp_memory"
PG_DB="mcp_memory"

red()   { printf '\033[31m%s\033[0m\n' "$*"; }
green() { printf '\033[32m%s\033[0m\n' "$*"; }
bold()  { printf '\033[1m%s\033[0m\n' "$*"; }

require_bin() {
    command -v "$1" >/dev/null || { red "missing required binary: $1"; exit 1; }
}

bucket_from_env() {
    if [ -f "tools/docker/.env" ]; then
        grep -E '^BACKUP_S3_BUCKET=' tools/docker/.env | head -1 | cut -d= -f2-
    fi
}

list_backups() {
    local bucket="$1"
    bold "Backups in s3://${bucket}/"
    echo "--- monthly (kept forever) ---"
    aws s3 ls "s3://${bucket}/monthly/" --recursive --human-readable | tail -20 || true
    echo "--- hourly (last 10 days) ---"
    aws s3 ls "s3://${bucket}/hourly/" --recursive --human-readable | tail -30 || true
}

interactive_pick() {
    local bucket="$1"
    bold "Most recent hourly backups:"
    aws s3 ls "s3://${bucket}/hourly/" --recursive | sort | tail -10 | nl
    echo
    read -rp "Enter S3 key (e.g. hourly/2026/04/30/mcp-memory-pgdump-...): " key
    echo "s3://${bucket}/${key}"
}

main() {
    require_bin aws
    require_bin docker

    if [ "${1:-}" = "--list" ]; then
        bucket="$(bucket_from_env)"
        [ -z "$bucket" ] && { red "BACKUP_S3_BUCKET not set in tools/docker/.env; pass bucket as arg"; exit 1; }
        list_backups "$bucket"
        exit 0
    fi

    if [ -n "${1:-}" ]; then
        s3_uri="$1"
    else
        bucket="$(bucket_from_env)"
        [ -z "$bucket" ] && { red "BACKUP_S3_BUCKET not set in tools/docker/.env; pass full s3:// URI as arg"; exit 1; }
        s3_uri="$(interactive_pick "$bucket")"
    fi

    case "$s3_uri" in
        s3://*) ;;
        *) red "expected s3:// URI, got: $s3_uri"; exit 1 ;;
    esac

    local_file="/tmp/$(basename "$s3_uri")"

    bold "==== RESTORE PLAN ===="
    echo "  source:     $s3_uri"
    echo "  download:   $local_file"
    echo "  postgres:   docker exec $POSTGRES_CONTAINER pg_restore --clean --if-exists -U $PG_USER -d $PG_DB"
    echo "  service:    will stop $SERVICE_CONTAINER, restore, then start it again"
    red "  destructive: yes — this REPLACES the current contents of database '$PG_DB'"
    echo
    read -rp "Type 'yes' to proceed: " confirm
    [ "$confirm" = "yes" ] || { echo "aborted"; exit 1; }

    bold "[1/6] downloading dump"
    aws s3 cp "$s3_uri" "$local_file"
    ls -lh "$local_file"

    bold "[2/6] sanity-checking dump file"
    file "$local_file"
    # Custom-format pg_dump files start with "PGDMP".
    if ! head -c 5 "$local_file" | grep -q PGDMP; then
        red "file does not look like a pg_dump custom-format file (no PGDMP magic). aborting."
        exit 1
    fi

    bold "[3/6] stopping $SERVICE_CONTAINER"
    docker stop "$SERVICE_CONTAINER" >/dev/null
    green "stopped"

    bold "[4/6] restoring into $POSTGRES_CONTAINER"
    docker exec -i "$POSTGRES_CONTAINER" pg_restore \
        --clean --if-exists --no-owner --no-privileges \
        -U "$PG_USER" -d "$PG_DB" < "$local_file" || {
        red "pg_restore exited non-zero. Service is still stopped — investigate before restarting."
        red "When ready: docker start $SERVICE_CONTAINER"
        exit 1
    }
    green "restore complete"

    bold "[5/6] restarting $SERVICE_CONTAINER"
    docker start "$SERVICE_CONTAINER" >/dev/null

    bold "[6/6] waiting for service health"
    for i in $(seq 1 30); do
        status=$(docker inspect --format '{{.State.Health.Status}}' "$SERVICE_CONTAINER" 2>/dev/null || echo "starting")
        if [ "$status" = "healthy" ]; then
            green "service healthy after ${i}0s"
            break
        fi
        sleep 10
    done

    bold "==== POST-RESTORE VERIFICATION ===="
    docker exec "$POSTGRES_CONTAINER" psql -U "$PG_USER" -d "$PG_DB" -c \
        "SELECT count(*) AS memories FROM memories;
         SELECT count(*) AS embeddings FROM memory_embeddings;"

    rm -f "$local_file"
    green "done"
}

main "$@"
