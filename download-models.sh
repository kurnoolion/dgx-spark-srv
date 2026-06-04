#!/usr/bin/env bash
#
# download-models.sh — bulk-download HuggingFace models into the shared cache.
# Idempotent (re-running re-verifies but doesn't re-download fully-cached files),
# retries each model up to MAX_RETRIES times with backoff, logs everything to
# both stdout and a file so it's safe to fire-and-forget overnight.
#
# Usage:
#   ./download-models.sh                       # use defaults from .env (VLLM_MODEL + TEI_MODEL)
#   ./download-models.sh Qwen/Qwen3-32B BAAI/bge-m3 ...   # explicit model IDs
#   ./download-models.sh -f models.txt          # list from file (one ID per line, # = comment)
#
# Env overrides:
#   LOG=/path/to.log     (default: $HOME/hf-download.log)
#   MAX_RETRIES=3
#   MIN_FREE_GB=100      (warn if /data/models has less free than this)
#
set -uo pipefail
cd "$(dirname "$0")"

LOG="${LOG:-$HOME/hf-download.log}"
MAX_RETRIES="${MAX_RETRIES:-3}"
RETRY_DELAYS=(10 30 60 120 300)
MIN_FREE_GB="${MIN_FREE_GB:-100}"

# Pull defaults from .env IF READABLE by the current user. If .env is mode 600
# root:root (the recommended posture) and you're running as a normal user, this
# silently skips — pass model IDs via positional args or `-f file.txt` instead.
# Same applies if .env is sops-encrypted.
if [[ -r .env ]]; then
  set -a; . ./.env; set +a
fi

export HF_HOME="${HF_HOME:-/data/models/hf-cache}"
export HF_HUB_ENABLE_HF_TRANSFER=1

# ─────────────────────── arg parsing ───────────────────────
models=()
if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//'
  exit 0
elif [[ "${1:-}" == "-f" && -n "${2:-}" ]]; then
  while IFS= read -r line; do
    line="${line%%#*}"           # strip comments
    line="${line#"${line%%[![:space:]]*}"}"   # ltrim
    line="${line%"${line##*[![:space:]]}"}"   # rtrim
    [[ -n "$line" ]] && models+=("$line")
  done < "$2"
elif (( $# > 0 )); then
  models=("$@")
else
  [[ -n "${VLLM_MODEL:-}" ]]         && models+=("$VLLM_MODEL")
  [[ -n "${TEI_MODEL:-}" ]]          && models+=("$TEI_MODEL")
  [[ -n "${TEI_RERANKER_MODEL:-}" ]] && models+=("$TEI_RERANKER_MODEL")
fi

# ─────────────────────── logging ───────────────────────
mkdir -p "$(dirname "$LOG")" 2>/dev/null || true
touch "$LOG" 2>/dev/null || { echo "ERROR cannot write log $LOG; set LOG=<path>"; exit 1; }
log() { printf '[%s] %s\n' "$(date -u +%FT%TZ)" "$*" | tee -a "$LOG"; }

current="<none>"
trap 'log "INTERRUPTED at: $current"; exit 130' INT TERM

# ─────────────────────── preflight ───────────────────────
(( ${#models[@]} > 0 )) || { log "ERROR no models to download (set VLLM_MODEL/TEI_MODEL/TEI_RERANKER_MODEL in .env, pass as args, or use -f file)"; exit 1; }

# Detect which HF CLI is available: new `hf` (huggingface_hub ≥ 0.24) preferred,
# old `huggingface-cli` as fallback. The new CLI uses `hf auth whoami` /
# `hf download`; the old uses `huggingface-cli whoami` / `huggingface-cli download`.
if command -v hf >/dev/null 2>&1; then
  HF_AUTH=(hf auth whoami)
  HF_DL=(hf download)
elif command -v huggingface-cli >/dev/null 2>&1; then
  HF_AUTH=(huggingface-cli whoami)
  HF_DL=(huggingface-cli download)
else
  log "ERROR neither 'hf' nor 'huggingface-cli' on PATH (install: uv tool install 'huggingface_hub[cli,hf_transfer]')"
  exit 1
fi

[[ -d "$HF_HOME" ]] || { log "ERROR HF_HOME=$HF_HOME does not exist"; exit 1; }
[[ -w "$HF_HOME" ]] || { log "ERROR HF_HOME=$HF_HOME not writable (are you in ml-users? 'newgrp ml-users' or re-login)"; exit 1; }
"${HF_AUTH[@]}" >/dev/null 2>&1 || { log "ERROR not logged in to HF (run: '${HF_AUTH[0]} ${HF_AUTH[1]/whoami/login}' or export HF_TOKEN)"; exit 1; }

# best-effort disk space check
free_gb=$(df -BG --output=avail /data/models 2>/dev/null | tail -1 | tr -dc '0-9')
if [[ -n "${free_gb:-}" && "$free_gb" -lt "$MIN_FREE_GB" ]]; then
  log "WARN /data/models has only ${free_gb}G free (threshold ${MIN_FREE_GB}G) — proceeding"
fi

log "starting download of ${#models[@]} model(s); HF_HOME=$HF_HOME; log=$LOG"
for m in "${models[@]}"; do log "  queued: $m"; done

# ─────────────────────── download loop ───────────────────────
succeeded=0
failed=()
for m in "${models[@]}"; do
  current="$m"
  log "──── $m ────"
  # Bare-name shorthand (e.g. "Qwen3-32B-AWQ" from .env) is for the LOAD path
  # only — the service resolver expands it to /data/local/<name>. The
  # downloader needs the full HF repo ID ("user/repo"), which we can't
  # derive automatically. Skip with a clear pointer instead of failing
  # opaquely against HF.
  if [[ "$m" != */* && "$m" != /* ]]; then
    log "SKIP $m: bare name has no HF repo ID. Download once with:"
    log "    ./hf-curl-download.sh <HF-org>/$m    # e.g. BAAI/$m or Qwen/$m"
    log "Then the bare name in .env works for the running service."
    failed+=("$m (bare-name; needs explicit HF repo ID)")
    continue
  fi
  attempt=1
  ok=0
  while (( attempt <= MAX_RETRIES )); do
    if "${HF_DL[@]}" "$m" 2>&1 | tee -a "$LOG"; then
      log "OK $m (attempt $attempt)"
      succeeded=$((succeeded+1))
      ok=1
      break
    fi
    log "FAIL $m (attempt $attempt / $MAX_RETRIES)"
    if (( attempt < MAX_RETRIES )); then
      idx=$(( attempt - 1 ))
      delay="${RETRY_DELAYS[$idx]:-300}"
      log "  sleeping ${delay}s before retry"
      sleep "$delay"
    fi
    attempt=$((attempt+1))
  done
  (( ok == 1 )) || failed+=("$m")
done

# ─────────────────────── summary ───────────────────────
log "──── summary ────"
log "succeeded: $succeeded / ${#models[@]}"
if (( ${#failed[@]} > 0 )); then
  log "FAILED: ${failed[*]}"
  exit 1
fi
log "all models downloaded successfully"
