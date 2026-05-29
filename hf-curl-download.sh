#!/usr/bin/env bash
#
# hf-curl-download.sh — curl-based HF model downloader for when `hf download`
# opens connections but doesn't transfer data through a stubborn proxy.
# Uses only curl (which we proved works via diagnose-hf.sh), resumable, retries
# aggressively, writes to a flat directory that vLLM/TEI can load directly.
#
# Usage:
#   ./hf-curl-download.sh <user/repo> [dest_dir]
#   ./hf-curl-download.sh Qwen/Qwen3-32B-AWQ
#   ./hf-curl-download.sh BAAI/bge-m3   /data/models/local/bge-m3
#
# Default dest: /data/models/local/<basename(repo)>
# Auth: uses $HF_TOKEN or reads ~/.cache/huggingface/token
#
# To point vLLM at the result, set in .env:
#   VLLM_MODEL=/data/models/local/Qwen3-32B-AWQ
#
set -uo pipefail

REPO="${1:-}"
[[ -z "$REPO" ]] && { echo "usage: $0 <user/repo> [dest_dir]"; exit 1; }
DEST="${2:-/data/models/local/${REPO##*/}}"

# Get HF token from env or token file
if [[ -z "${HF_TOKEN:-}" ]]; then
  for f in ~/.cache/huggingface/token "${HF_HOME:-}/token"; do
    [[ -r "$f" ]] && { HF_TOKEN=$(cat "$f"); break; }
  done
fi
[[ -z "${HF_TOKEN:-}" ]] && { echo "ERROR no HF_TOKEN (set env or run: hf auth login)"; exit 1; }

AUTH_HEADER=(-H "Authorization: Bearer $HF_TOKEN")

mkdir -p "$DEST"
cd "$DEST"

echo "═══════════════════════════════════════════════════════════"
echo " Repo: $REPO"
echo " Dest: $DEST"
echo "═══════════════════════════════════════════════════════════"

# 1. fetch the file list from HF API (recursive — handles subdirs)
echo "[*] fetching file list ..."
TREE_URL="https://huggingface.co/api/models/${REPO}/tree/main?recursive=true"
FILES_JSON=$(curl -fsSL --max-time 30 "${AUTH_HEADER[@]}" "$TREE_URL") \
  || { echo "ERROR could not fetch file list from $TREE_URL"; exit 1; }

mapfile -t FILES < <(echo "$FILES_JSON" | python3 -c "
import json, sys
data = json.load(sys.stdin)
for item in data:
    if item.get('type') == 'file':
        print(item['path'])
")

NUM=${#FILES[@]}
[[ $NUM -eq 0 ]] && { echo "ERROR no files found in $REPO"; exit 1; }
echo "[*] $NUM files to download"

# 2. compute total bytes for progress narration (best effort, optional)
TOTAL=$(echo "$FILES_JSON" | python3 -c "
import json, sys
data = json.load(sys.stdin)
print(sum(item.get('size', 0) for item in data if item.get('type')=='file'))
")
HUMAN=$(numfmt --to=iec "$TOTAL" 2>/dev/null || echo "$TOTAL bytes")
echo "[*] ≈ $HUMAN total"

# 3. download each file with resume + retry
trap 'echo; echo "INTERRUPTED at file $i/$NUM: ${current:-?}"; exit 130' INT TERM

i=0
for f in "${FILES[@]}"; do
  i=$((i+1))
  current="$f"
  echo
  echo "── [$i/$NUM] $f ──"
  mkdir -p "$(dirname "$f")"

  # outer retry — restart if curl gives up after all its inner retries
  outer=0
  until curl -fL --progress-bar \
      --continue-at - \
      --retry 100 \
      --retry-all-errors \
      --retry-delay 10 \
      --retry-max-time 0 \
      --connect-timeout 30 \
      "${AUTH_HEADER[@]}" \
      -o "$f" \
      "https://huggingface.co/${REPO}/resolve/main/${f}"; do
    outer=$((outer+1))
    echo "[!] curl exited; outer-retry #$outer for $f in 30s"
    sleep 30
  done
done

echo
echo "═══════════════════════════════════════════════════════════"
echo " DONE — $NUM files in $DEST"
echo " For vLLM: set VLLM_MODEL=$DEST in /data/srv/.env"
echo "═══════════════════════════════════════════════════════════"
