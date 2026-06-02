#!/usr/bin/env bash
#
# vllm-watch.sh — live monitor of vLLM resource usage (Ctrl-C to exit).
# Shows GPU memory + util, container CPU/RAM, and vLLM internals (KV cache,
# request queue depth) refreshed every N seconds.
#
# Usage:
#   ./vllm-watch.sh                # default 2s refresh
#   ./vllm-watch.sh 5              # 5s refresh
#
# All sub-commands are best-effort — if the container isn't running or vLLM's
# /metrics endpoint isn't reachable yet (e.g. model still loading), the section
# prints a short note instead of failing the whole watcher.
#
set -uo pipefail
cd "$(dirname "$0")"

INTERVAL="${1:-2}"

print_state() {
  printf '%s   vLLM watch (refresh %ss · Ctrl-C to exit)\n' "$(date +%H:%M:%S)" "$INTERVAL"

  printf '\n── GPU (memory MiB, util %%) ────────────────────────────────────\n'
  nvidia-smi --query-gpu=memory.used,memory.free,memory.total,utilization.gpu \
    --format=csv,nounits 2>/dev/null || echo "  nvidia-smi unavailable"

  printf '\n── vLLM container ───────────────────────────────────────────────\n'
  docker stats srv-vllm-1 --no-stream \
    --format "  CPU={{.CPUPerc}}   MEM={{.MemUsage}} ({{.MemPerc}})   PIDS={{.PIDs}}" \
    2>/dev/null || echo "  srv-vllm-1 container not running"

  printf '\n── vLLM internals (KV cache %%, queued / running / swapped) ─────\n'
  docker compose -f compose.inference.yml exec -T vllm \
    curl -fsS http://localhost:8000/metrics 2>/dev/null \
    | grep -E '^vllm:(gpu_cache_usage_perc|num_requests_running|num_requests_waiting|num_requests_swapped) ' \
    | awk '{printf "  %-50s %s\n", $1, $2}' \
    || echo "  /metrics unreachable (model still loading, or vllm down?)"
}

trap 'echo; echo "[exited]"; exit 0' INT TERM

while true; do
  clear 2>/dev/null || printf '\033[H\033[2J'   # fall back to ANSI clear if tput missing
  print_state
  sleep "$INTERVAL"
done
