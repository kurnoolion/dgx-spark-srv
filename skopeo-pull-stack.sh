#!/usr/bin/env bash
#
# skopeo-pull-stack.sh — pull every image the apex-spark-01 stack needs via
# skopeo (proxy-friendly), then docker-load each. Workaround for the case
# where `docker pull` fails through the corp proxy but skopeo + curl don't.
#
# Auto-extracts the image list from compose*.yml + docker-compose.yml.
# Handles NGC auth for nvcr.io images. Idempotent — skips images already
# present locally. Retries each pull (default 3×) with backoff.
#
# Usage:
#   ./skopeo-pull-stack.sh                                # all images from compose
#   ./skopeo-pull-stack.sh nvcr.io/nvidia/vllm:25.11-py3 redis:7    # explicit
#   NGC_API_KEY=… ./skopeo-pull-stack.sh                  # required for nvcr.io
#
# Env:
#   NGC_API_KEY    NGC API key (https://ngc.nvidia.com/setup/api-key)
#   TMP            scratch dir for tarballs (default: /tmp)
#   KEEP_TARS=1    keep tarballs after loading (default: delete)
#   MAX_RETRIES    per-image retry count (default: 3)
#   LOG=<path>     log file (default: ~/skopeo-pull-stack.log)
#
set -uo pipefail
cd "$(dirname "$0")"

TMP="${TMP:-/tmp}"
MAX_RETRIES="${MAX_RETRIES:-3}"
KEEP_TARS="${KEEP_TARS:-0}"
LOG="${LOG:-$HOME/skopeo-pull-stack.log}"

mkdir -p "$TMP"
touch "$LOG" 2>/dev/null || LOG=/dev/stdout
log() { printf '[%s] %s\n' "$(date -u +%FT%TZ)" "$*" | tee -a "$LOG"; }

# ── preflight ──
command -v skopeo >/dev/null || { log "ERROR skopeo not installed (sudo apt install skopeo)"; exit 1; }
command -v docker >/dev/null || { log "ERROR docker not installed"; exit 1; }
docker info >/dev/null 2>&1  || { log "ERROR can't reach docker daemon (in docker group? newgrp docker)"; exit 1; }

# ── gather image list ──
declare -a IMAGES
if (( $# > 0 )); then
  IMAGES=("$@")
else
  mapfile -t IMAGES < <(
    grep -rhE '^[[:space:]]+image:[[:space:]]' compose*.yml docker-compose.yml 2>/dev/null \
      | awk '{print $2}' \
      | sed 's/[#"'"'"'].*$//' | sed 's/[[:space:]]//g' \
      | sort -u
  )
fi

(( ${#IMAGES[@]} > 0 )) || { log "ERROR no images found (in compose files? pass IDs on CLI)"; exit 1; }

log "Pulling ${#IMAGES[@]} image(s) — tmp=$TMP — log=$LOG"
for img in "${IMAGES[@]}"; do log "  queued: $img"; done

# ── helpers ──
# Normalize raw image to skopeo's source URI (without docker:// prefix).
# Rules: single-segment → docker.io/library; two-segment w/o dot or colon →
# docker.io; otherwise treat first segment as registry host.
to_src() {
  local raw="$1" repo tag first
  tag="${raw##*:}"
  repo="${raw%:*}"
  first="${repo%%/*}"
  if [[ "$repo" != */* ]]; then
    echo "docker.io/library/$repo:$tag"
  elif [[ "$first" == *.* || "$first" == *:* ]]; then
    echo "$repo:$tag"
  else
    echo "docker.io/$repo:$tag"
  fi
}

# Tarball path — sanitize / and : into _
to_tar() { echo "$TMP/$(echo "$1" | tr '/:' '__').tar"; }

trap 'log "INTERRUPTED at ${current:-?}"; exit 130' INT TERM

# ── main loop ──
succeeded=0; skipped=0; declare -a failed=()
for img in "${IMAGES[@]}"; do
  current="$img"
  log ""
  log "──── $img ────"

  # already in local image store?
  if docker image inspect "$img" >/dev/null 2>&1; then
    log "SKIP: already present locally"
    skipped=$((skipped+1))
    continue
  fi

  SRC="docker://$(to_src "$img")"
  TAR="$(to_tar "$img")"
  DST="docker-archive:${TAR}:${img}"

  # build skopeo args (registry-specific auth)
  declare -a SK_ARGS
  SK_ARGS=(copy --src-tls-verify=true)
  case "$img" in
    nvcr.io/*)
      if [[ -n "${NGC_API_KEY:-}" ]]; then
        SK_ARGS+=(--src-creds "\$oauthtoken:${NGC_API_KEY}")
      else
        log "WARN no NGC_API_KEY in env — nvcr.io pull will likely fail. Set NGC_API_KEY=… and re-run."
      fi
      ;;
  esac
  SK_ARGS+=("$SRC" "$DST")

  # pull with retries
  log "skopeo copy $SRC → $TAR"
  ok=0
  for ((a=1; a<=MAX_RETRIES; a++)); do
    if skopeo "${SK_ARGS[@]}" 2>&1 | tee -a "$LOG"; then
      ok=1; break
    fi
    log "FAIL skopeo (attempt $a/$MAX_RETRIES) for $img"
    sleep $((a*10))
  done
  if (( ok == 0 )); then
    log "ERROR skopeo failed permanently for $img"
    failed+=("$img"); continue
  fi

  # load into docker
  log "docker load $TAR"
  if docker load -i "$TAR" 2>&1 | tee -a "$LOG"; then
    log "OK: $img loaded"
    succeeded=$((succeeded+1))
  else
    log "ERROR docker load failed for $img"
    failed+=("$img")
  fi

  # cleanup tarball unless KEEP_TARS=1
  (( KEEP_TARS == 0 )) && rm -f "$TAR"
done

# ── summary ──
log ""
log "──── summary ────"
log "succeeded: $succeeded"
log "skipped:   $skipped (already present)"
log "failed:    ${#failed[@]}"
if (( ${#failed[@]} > 0 )); then
  for f in "${failed[@]}"; do log "  - $f"; done
  exit 1
fi
