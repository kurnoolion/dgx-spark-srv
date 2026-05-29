#!/usr/bin/env bash
#
# diagnose-hf.sh — collect HF download diagnostics for an apex-spark-01 stall.
# Read-only. Run as a normal user (mohan); will use sudo only where necessary.
# Output is structured with section headers — paste it back for analysis.
#
set -u
cd "$(dirname "$0")"
HF_CACHE="${HF_HOME:-/data/models/hf-cache}"
LOG="${LOG:-$HOME/hf-download.log}"

hr()  { printf '\n────────── %s ──────────\n' "$*"; }
have(){ command -v "$1" >/dev/null 2>&1; }
maybe(){ "$@" 2>&1 || echo "(failed: $*)"; }

# ── 0. environment summary ──
hr "ENV / TOOLING"
echo "user        : $(id -un) ($(id -u)); groups: $(id -nG)"
echo "HF_HOME     : ${HF_HOME:-<unset>}"
echo "HF_HUB_ENABLE_HF_TRANSFER : ${HF_HUB_ENABLE_HF_TRANSFER:-<unset>}"
echo "HF_TOKEN    : $( [[ -n "${HF_TOKEN:-}" ]] && echo "<set, ${#HF_TOKEN} chars>" || echo "<unset>")"
echo "HTTP_PROXY  : ${HTTP_PROXY:-<unset>}"
echo "HTTPS_PROXY : ${HTTPS_PROXY:-<unset>}"
echo "NO_PROXY    : ${NO_PROXY:-<unset>}"
echo "hf binary   : $(have hf && which hf || echo '(not on PATH)')"
echo "huggingface-cli : $(have huggingface-cli && which huggingface-cli || echo '(not on PATH)')"
have hf  && echo "hf version  : $(hf --version 2>&1)"
echo "curl version: $(curl --version 2>/dev/null | head -1)"
echo "free disk   : $(df -h "$HF_CACHE" 2>/dev/null | awk 'NR==2{print $4" avail of "$2}')"

# ── 1. hf processes ──
hr "ACTIVE HF PROCESSES"
ps -eo pid,etime,pcpu,pmem,cmd | grep -E '[h]f download|[h]uggingface' || echo "(none)"

# ── 2. socket state to https ports ──
hr "TCP SOCKETS (filter: port 443)"
ss -tn 2>/dev/null | awk 'NR==1 || /:443 /' | head -30 || echo "(ss unavailable)"
hr "CLOSE_WAIT count"
echo "close-wait  : $(ss -tn state close-wait 2>/dev/null | wc -l) sockets"
echo "established : $(ss -tn state established 2>/dev/null | grep -c :443) on :443"

# ── 3. recent log tail ──
hr "DOWNLOAD LOG TAIL ($LOG, last 40 lines)"
if [[ -f "$LOG" ]]; then tail -40 "$LOG"; else echo "(no log file)"; fi

# ── 4. cache state ──
hr "CACHE STATE ($HF_CACHE)"
du -sh "$HF_CACHE" 2>/dev/null
echo
echo "── repos in cache ──"
ls -la "$HF_CACHE/hub/" 2>/dev/null | head -20 || echo "(no hub dir)"
echo
echo "── largest blobs (top 10) ──"
sudo find "$HF_CACHE/hub" -type f -printf '%s %p\n' 2>/dev/null \
  | sort -rn | head -10 | awk '{printf "%10.1fM  %s\n", $1/1024/1024, $2}' \
  || echo "(no blobs / permission denied)"
echo
echo "── partial (incomplete) blobs ──"
sudo find "$HF_CACHE/hub" -name '*.incomplete' -o -name 'tmp*' 2>/dev/null \
  | head -20 || echo "(none — or no permission)"

# ── 5. HF connectivity probe ──
hr "HF API CONNECTIVITY"
echo "── whoami via curl ──"
maybe curl -sS -o /dev/null -w "HTTP %{http_code}  %{size_download}B  %{time_total}s\n" \
  --max-time 15 \
  https://huggingface.co/api/whoami-v2 \
  -H "Authorization: Bearer ${HF_TOKEN:-$(sudo -n grep ^HF_TOKEN= /data/srv/.env 2>/dev/null | cut -d= -f2-)}"

echo "── small file fetch (config.json ~1KB) ──"
maybe curl -sSL -o /dev/null -w "HTTP %{http_code}  %{size_download}B  %{time_total}s\n" \
  --max-time 30 \
  https://huggingface.co/Qwen/Qwen3-32B-AWQ/resolve/main/config.json

echo "── large file probe (HEAD request for first model shard) ──"
maybe curl -sSL -I -o /dev/null -w "HTTP %{http_code}  Content-Length: %header{content-length}  %{time_total}s\n" \
  --max-time 30 \
  https://huggingface.co/Qwen/Qwen3-32B-AWQ/resolve/main/model-00001-of-00004.safetensors

echo "── 10MB range fetch (does the proxy let through medium chunks?) ──"
maybe curl -sSL -o /dev/null -w "HTTP %{http_code}  %{size_download}B  %{time_total}s  (%{speed_download}B/s)\n" \
  --max-time 60 \
  --range 0-10485759 \
  https://huggingface.co/Qwen/Qwen3-32B-AWQ/resolve/main/model-00001-of-00004.safetensors

# ── 6. auth state ──
hr "HF AUTH"
if have hf; then
  maybe hf auth whoami
elif have huggingface-cli; then
  maybe huggingface-cli whoami
fi
echo
echo "── token files ──"
ls -la "$HF_CACHE/token" "$HF_CACHE/stored_tokens" 2>/dev/null
ls -la "$HOME/.cache/huggingface/token" "$HOME/.cache/huggingface/stored_tokens" 2>/dev/null

# ── 7. proxy daemon config (visibility) ──
hr "PROXY (docker daemon view — for cross-reference)"
systemctl show docker --property=Environment 2>/dev/null | head -3 || echo "(systemctl unavailable)"

hr "DONE"
echo "Paste everything above (or save to file: ./diagnose-hf.sh > /tmp/hf-diag.txt 2>&1)"
