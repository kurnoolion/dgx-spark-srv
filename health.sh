#!/usr/bin/env bash
#
# health.sh — apex-spark-01 daily health checks (invoked by `make health`)
#
# Evaluates each check as PASS / WARN / FAIL and exits non-zero if anything
# FAILs, so it doubles as a cron/monitoring probe. Read-only.
#
# Thresholds (override via env): DISK_WARN=85  GPU_TEMP_WARN=80
#
set -uo pipefail                 # not -e: run every check even if one fails
cd "$(dirname "$0")"

DISK_WARN="${DISK_WARN:-85}"
GPU_TEMP_WARN="${GPU_TEMP_WARN:-80}"
COMPOSE="docker compose -f docker-compose.yml -f compose.inference.yml -f compose.gateway.yml -f compose.apps.yml -f compose.observability.yml"
SERVICES="postgres redis qdrant minio vllm ollama tei caddy example-app prometheus grafana cadvisor node-exporter dcgm-exporter"

fails=0; warns=0
ok()   { printf '  \e[32mPASS\e[0m %s\n' "$*"; }
warn() { printf '  \e[33mWARN\e[0m %s\n' "$*"; warns=$((warns+1)); }
fail() { printf '  \e[31mFAIL\e[0m %s\n' "$*"; fails=$((fails+1)); }
hdr()  { printf '\n\e[1m%s\e[0m\n' "$*"; }

# ── Services ───────────────────────────────────────────────────────────────
hdr "Services"
for svc in $SERVICES; do
  cid=$($COMPOSE ps -q "$svc" 2>/dev/null)
  if [[ -z "$cid" ]]; then warn "$svc — not created"; continue; fi
  state=$(docker inspect -f '{{.State.Status}}' "$cid" 2>/dev/null)
  health=$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$cid" 2>/dev/null)
  if [[ "$state" == running && ( "$health" == healthy || "$health" == none ) ]]; then
    ok "$svc — running${health:+ ($health)}"
  elif [[ "$state" == running && "$health" == starting ]]; then
    warn "$svc — starting (model loading?)"
  else
    fail "$svc — state=$state health=$health"
  fi
done

# ── GPU ──────────────────────────────────────────────────────────────────
hdr "GPU"
if command -v nvidia-smi >/dev/null 2>&1; then
  line=$(nvidia-smi --query-gpu=temperature.gpu,memory.used,memory.total \
         --format=csv,noheader,nounits 2>/dev/null | head -1)
  temp=$(awk -F, '{gsub(/ /,"");print $1}' <<<"$line")
  used=$(awk -F, '{gsub(/ /,"");print $2}' <<<"$line")
  total=$(awk -F, '{gsub(/ /,"");print $3}' <<<"$line")
  if [[ -n "${temp:-}" ]]; then
    if (( temp >= GPU_TEMP_WARN )); then warn "temp ${temp}C (>= ${GPU_TEMP_WARN})"; else ok "temp ${temp}C"; fi
    (( total > 0 )) && ok "memory ${used}/${total} MiB ($(( used*100/total ))%)"
  else
    warn "nvidia-smi returned no data"
  fi
else
  fail "nvidia-smi not found"
fi

# ── Disk ───────────────────────────────────────────────────────────────────
hdr "Disk usage"
# /home is a bind of /data, so it shares /data's filesystem — not listed separately.
for m in / /data /var/lib/docker; do
  use=$(df --output=pcent "$m" 2>/dev/null | tail -1 | tr -dc '0-9')
  if [[ -z "$use" ]]; then warn "$m — not found"; continue; fi
  if (( use >= DISK_WARN )); then fail "$m — ${use}% full (>= ${DISK_WARN})"; else ok "$m — ${use}%"; fi
done

# ── /data split (XFS project quotas) ───────────────────────────────────────
hdr "Storage split (/data quotas)"
if mountpoint -q /data 2>/dev/null; then
  if sudo -n xfs_quota -x -c 'report -h -p' /data >/tmp/.apexq 2>/dev/null; then
    sed 's/^/  /' /tmp/.apexq; rm -f /tmp/.apexq
  else
    warn "could not read project quota (needs sudo; run: sudo xfs_quota -x -c 'report -h' /data)"
  fi
else
  warn "/data not a separate mount yet — storage not set up (see setup-storage.sh)"
fi

# ── Inference endpoints ────────────────────────────────────────────────────
hdr "Inference endpoints"
vcid=$($COMPOSE ps -q vllm 2>/dev/null)
if [[ -n "$vcid" ]]; then
  docker exec "$vcid" curl -fsS localhost:8000/health >/dev/null 2>&1 \
    && ok "vLLM /health" || warn "vLLM /health not ready (loading or down)"
fi
ocid=$($COMPOSE ps -q ollama 2>/dev/null)
if [[ -n "$ocid" ]]; then
  docker exec "$ocid" ollama list >/dev/null 2>&1 \
    && ok "Ollama responding" || warn "Ollama not responding"
fi

# ── Summary ──────────────────────────────────────────────────────────────
hdr "Summary"
printf '  %d FAIL, %d WARN\n' "$fails" "$warns"
(( fails > 0 )) && exit 1 || exit 0
