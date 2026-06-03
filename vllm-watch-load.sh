#!/usr/bin/env bash
#
# vllm-watch-load.sh — saturation-focused vLLM monitor for load testing.
# Tier-1 metrics only: queue depth, KV cache %, preemptions, GPU util, memory.
# Companion to vllm-watch.sh (which has the richer, slower-refresh view).
#
# Usage:
#   ./vllm-watch-load.sh        # default 1s refresh (snappier than vllm-watch)
#   ./vllm-watch-load.sh 2      # custom interval
#
# Best used in a side terminal while running load tests against /v1.
#
set -uo pipefail
cd "$(dirname "$0")"

INTERVAL="${1:-1}"

print_state() {
  printf '%s   vLLM LOAD watch (refresh %ss · Ctrl-C to exit)\n' "$(date +%H:%M:%S)" "$INTERVAL"

  printf '\n── saturation signals (from vllm /metrics) ──────────────────────\n'
  local metrics
  metrics=$(docker compose -f compose.inference.yml exec -T vllm \
              curl -fsS http://localhost:8000/metrics 2>/dev/null || true)
  if [[ -z "$metrics" ]]; then
    echo "  /metrics unreachable (vllm down or starting up?)"
  else
    echo "$metrics" \
      | grep -E '^vllm:(num_requests_(running|waiting|swapped)|kv_cache_usage_perc|num_preemptions_total) ' \
      | awk '{printf "  %-55s %s\n", $1, $2}'
  fi

  printf '\n── system pressure ──────────────────────────────────────────────\n'
  local gpu_util
  gpu_util=$(nvidia-smi --query-gpu=utilization.gpu --format=csv,noheader,nounits 2>/dev/null) || gpu_util="?"
  printf "  GPU util:    %s%%\n" "$gpu_util"

  local mem_used mem_total mem_avail
  read -r mem_used mem_total mem_avail < <(free -m | awk '/^Mem:/{print $3, $2, $7}')
  if [[ -n "$mem_total" && "$mem_total" -gt 0 ]]; then
    local mem_pct=$(( (mem_used * 100) / mem_total ))
    printf "  Mem used:    %d MiB / %d MiB (%d%%)   avail: %d MiB\n" \
           "$mem_used" "$mem_total" "$mem_pct" "$mem_avail"
  else
    echo "  free -h unavailable"
  fi

  printf '\n── thresholds ───────────────────────────────────────────────────\n'
  printf '  HEALTHY:   waiting=0   swapped=0   kv_cache<70%%   gpu_util 95-100%% in gen\n'
  printf '  WARNING:   waiting<10   kv_cache 70-90%%   preemptions ticking up\n'
  printf '  CRITICAL:  waiting growing   kv_cache>90%%   preemptions rising   mem>95%%\n'
}

trap 'echo; echo "[exited]"; exit 0' INT TERM

while true; do
  clear 2>/dev/null || printf '\033[H\033[2J'
  print_state
  sleep "$INTERVAL"
done
