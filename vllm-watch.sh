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

  printf '\n── Unified memory pool (GPU+CPU share this) ─────────────────────\n'
  # On DGX Spark / GB10 nvidia-smi can't separate GPU memory — they're the same
  # pool. `free -h` is the authoritative number; nvidia-smi gives util %% only.
  free -h | awk 'NR==1 || /^Mem:/ {print "  "$0}'
  local gpu_util
  gpu_util=$(nvidia-smi --query-gpu=utilization.gpu --format=csv,noheader,nounits 2>/dev/null) \
    && printf "  GPU util: %s%%\n" "$gpu_util"

  printf '\n── vLLM container (process-level only — NOT GPU allocation) ─────\n'
  docker stats srv-vllm-1 --no-stream \
    --format "  CPU={{.CPUPerc}}   container-MEM={{.MemUsage}} ({{.MemPerc}})   PIDS={{.PIDs}}" \
    2>/dev/null || echo "  srv-vllm-1 container not running"
  echo "  (vLLM's 96 GB stake doesn't show here on unified memory — see 'free' above)"

  printf '\n── vLLM internals (cache + request stats from /metrics) ─────────\n'
  local metrics
  metrics=$(docker compose -f compose.inference.yml exec -T vllm \
              curl -fsS http://localhost:8000/metrics 2>/dev/null || true)
  if [[ -z "$metrics" ]]; then
    echo "  /metrics endpoint unreachable (vllm down or not yet listening?)"
  else
    # Prefer specific well-known names; fall back to all vllm: gauges if names differ across versions.
    local interesting
    interesting=$(echo "$metrics" \
      | grep -E '^vllm:(gpu_cache_usage_perc|kv_cache_usage_perc|num_requests_running|num_requests_waiting|num_requests_swapped|prefix_cache_hit_rate|prefix_cache_queries) ' \
      | head -10)
    if [[ -z "$interesting" ]]; then
      interesting=$(echo "$metrics" \
        | grep '^vllm:' \
        | grep -vE '_(bucket|count|sum|created)( |\{)' \
        | head -8)
    fi
    if [[ -z "$interesting" ]]; then
      echo "  /metrics has no vllm:* gauges (build moved them — raw probe still useful)"
    else
      echo "$interesting" | awk '{printf "  %-55s %s\n", $1, $2}'
    fi
  fi
}

trap 'echo; echo "[exited]"; exit 0' INT TERM

while true; do
  clear 2>/dev/null || printf '\033[H\033[2J'   # fall back to ANSI clear if tput missing
  print_state
  sleep "$INTERVAL"
done
