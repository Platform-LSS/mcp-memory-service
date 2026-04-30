## pg_dump + aws-cli, runs in a loop and uploads dumps to S3.
## Built by docker-compose.backup.yml.
##
## Pinned to postgres:16-alpine so pg_dump matches the pgvector/pgvector:pg16
## server major version. Bumping the server major version requires bumping
## this base image too.

FROM postgres:16-alpine

RUN apk add --no-cache \
    aws-cli \
    bash \
    coreutils \
    tzdata

ENV TZ=UTC

WORKDIR /opt/backup
COPY entrypoint.sh backup.sh /opt/backup/
RUN chmod +x /opt/backup/entrypoint.sh /opt/backup/backup.sh

# Healthcheck: fails if no successful backup in the last 5 hours
# (interval is 4h, so 5h = one missed cycle).
HEALTHCHECK --interval=10m --timeout=5s --start-period=5m --retries=2 \
    CMD test -f /tmp/last_success && \
        test $(( $(date +%s) - $(cat /tmp/last_success) )) -lt 18000 || exit 1

ENTRYPOINT ["/opt/backup/entrypoint.sh"]
