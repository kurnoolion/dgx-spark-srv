#!/usr/bin/env bash
#
# backup.sh — apex-spark-01 backup (invoked by `make backup`)
#
# Logical Postgres dump + consistent Qdrant snapshot + restic of the durable
# data and config. Safe to run while the stack is up.
#
# Off-box push happens ONLY if RESTIC_REPO is set in .env. Until then it stages
# locally and warns that there is no disaster-recovery copy yet — so you can wire
# the scaffold now and point it at a target later.
#
set -euo pipefail
cd "$(dirname "$0")"

[[ -f .env ]] || { echo "[backup] no .env in $(pwd)"; exit 1; }
set -a; . ./.env; set +a

BACKUP_DIR="${BACKUP_DIR:-/data/srv/backups}"
LOCAL_KEEP_DAYS="${LOCAL_KEEP_DAYS:-7}"
TS="$(date +%F_%H%M%S)"
STAGE="$BACKUP_DIR/$TS"
COMPOSE="docker compose -f docker-compose.yml -f compose.inference.yml -f compose.gateway.yml -f compose.apps.yml -f compose.observability.yml"
log(){ echo "[backup] $*"; }

mkdir -p "$STAGE"; chmod 700 "$STAGE"     # staging holds cleartext dumps — keep tight
log "staging -> $STAGE"

# 1. Postgres — logical dump (consistent point-in-time)
log "pg_dump $PG_DB"
$COMPOSE exec -T postgres pg_dump -U "$PG_USER" "$PG_DB" | gzip > "$STAGE/postgres-$PG_DB.sql.gz"

# 2. Redis — flush current state to disk (best effort)
log "redis BGSAVE"
$COMPOSE exec -T redis redis-cli BGSAVE >/dev/null 2>&1 || log "  (redis save skipped)"

# 3. Qdrant — consistent snapshot via API; lands in the bind-mounted
#    /data/srv/data/qdrant-snapshots dir (multi-arch throwaway curl container).
log "qdrant snapshot"
docker run --rm --network apex curlimages/curl:latest \
  -s -X POST http://qdrant:6333/snapshots >/dev/null 2>&1 || log "  (qdrant snapshot skipped)"

# 4. Stack config (compose + Caddyfile + .env — secrets included, restic encrypts)
log "config archive"
tar czf "$STAGE/config.tar.gz" -C . *.yml Caddyfile Makefile .env 2>/dev/null || true

# 5. Off-box push via restic (only if configured)
if [[ -n "${RESTIC_REPO:-}" ]]; then
  command -v restic >/dev/null || { log "ERROR: RESTIC_REPO set but restic not installed"; exit 1; }
  export RESTIC_REPOSITORY="$RESTIC_REPO"
  log "restic backup -> $RESTIC_REPO"
  restic snapshots >/dev/null 2>&1 || { log "initialising repo"; restic init; }
  restic backup --tag apex-spark \
    "$STAGE" \
    /data/srv/data/qdrant-snapshots \
    /data/srv/data/minio \
    /data/srv/data/redis \
    /data/srv/data/caddy \
    /data/srv/data/grafana \
    /home
  log "restic forget --prune (retention)"
  restic forget --prune \
    --keep-daily   "${KEEP_DAILY:-14}" \
    --keep-weekly  "${KEEP_WEEKLY:-8}" \
    --keep-monthly "${KEEP_MONTHLY:-6}"
else
  log "RESTIC_REPO not set — staged LOCALLY ONLY, no off-box DR copy."
  log "  set RESTIC_REPO + RESTIC_PASSWORD in .env when ready (see .env.example)."
fi

# 6. Prune old local staging
find "$BACKUP_DIR" -maxdepth 1 -type d -name '20*' -mtime +"$LOCAL_KEEP_DAYS" \
  -exec rm -rf {} + 2>/dev/null || true

log "done: $STAGE"
