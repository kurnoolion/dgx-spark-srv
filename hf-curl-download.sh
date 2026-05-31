#!/usr/bin/env bash
#
# hf-curl-download.sh — curl-based HF model downloader for when `hf download`
# opens connections but doesn't transfer data through a stubborn proxy.
# Uses only curl (which we proved works via diagnose-hf.sh), resumable, retries
# aggressively, writes to a flat directory that vLLM/TEI can load directly,
# and VERIFIES EACH FILE'S SIZE post-download against the HF API's expected size
# (catches proxy mid-stream truncations that leave curl exiting 0 with a short file).
#
# Usage:
#   ./hf-curl-download.sh <user/repo> [dest_dir]
#   ./hf-curl-download.sh Qwen/Qwen3-32B-AWQ
#   ./hf-curl-download.sh BAAI/bge-m3   /data/models/local/bge-m3
#
# Default dest: /data/models/local/<basename(repo)>
# Auth: uses $HF_TOKEN or reads ~/.cache/huggingface/token
#
# Env overrides:
#   MAX_FILE_ATTEMPTS=10   per-file outer attempts before giving up
#
# To point vLLM at the result, set in .env:
#   VLLM_MODEL=/data/models/local/Qwen3-32B-AWQ
#
set -uo pipefail

REPO="${1:-}"
[[ -z "$REPO" ]] && { echo "usage: $0 <user/repo> [dest_dir]"; exit 1; }
DEST="${2:-/data/models/local/${REPO##*/}}"
MAX_FILE_ATTEMPTS="${MAX_FILE_ATTEMPTS:-10}"

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

# 2. parse paths + sizes (tab-separated)
mapfile -t FILE_LINES < <(echo "$FILES_JSON" | python3 -c "
import json, sys
data = json.load(sys.stdin)
for item in data:
    if item.get('type') == 'file':
        print(f\"{item['path']}\t{item.get('size', -1)}\")
")

NUM=${#FILE_LINES[@]}
[[ $NUM -eq 0 ]] && { echo "ERROR no files found in $REPO"; exit 1; }

# 3. total bytes for progress narration
TOTAL=$(echo "$FILES_JSON" | python3 -c "
import json, sys
data = json.load(sys.stdin)
print(sum(item.get('size', 0) for item in data if item.get('type')=='file'))
")
HUMAN=$(numfmt --to=iec "$TOTAL" 2>/dev/null || echo "$TOTAL bytes")
echo "[*] $NUM files, ≈ $HUMAN total"

# 4. download each file with resume + retry + size verification
trap 'echo; echo "INTERRUPTED at file $i/$NUM: ${current:-?}"; exit 130' INT TERM

declare -a FAILED=()
declare -a SKIPPED=()
i=0
for line in "${FILE_LINES[@]}"; do
  i=$((i+1))
  f="${line%$'\t'*}"
  exp_size="${line#*$'\t'}"
  current="$f"
  echo
  echo "── [$i/$NUM] $f (expected: ${exp_size} bytes) ──"
  mkdir -p "$(dirname "$f")"

  # Fast path: if file already exists at exactly the right size, skip
  if [[ -f "$f" && "$exp_size" != "-1" ]]; then
    act_size=$(stat -c %s "$f" 2>/dev/null || echo 0)
    if [[ "$act_size" == "$exp_size" ]]; then
      echo "  → SKIP (already complete, $act_size bytes)"
      SKIPPED+=("$f")
      continue
    fi
  fi

  attempt=0
  ok=0
  while (( attempt < MAX_FILE_ATTEMPTS )); do
    attempt=$((attempt+1))

    # curl: --continue-at - resumes from local size; fresh download if file absent
    if curl -fL --progress-bar \
        --continue-at - \
        --retry 100 \
        --retry-all-errors \
        --retry-delay 10 \
        --retry-max-time 0 \
        --connect-timeout 30 \
        "${AUTH_HEADER[@]}" \
        -o "$f" \
        "https://huggingface.co/${REPO}/resolve/main/${f}"; then

      # Size-verify post-download (skip if expected size unknown)
      if [[ "$exp_size" == "-1" || -z "$exp_size" ]]; then
        echo "  → downloaded (expected size unknown, can't verify)"
        ok=1
        break
      fi
      act_size=$(stat -c %s "$f" 2>/dev/null || echo 0)
      if [[ "$act_size" == "$exp_size" ]]; then
        echo "  → OK ($act_size bytes verified)"
        ok=1
        break
      else
        diff=$((exp_size - act_size))
        echo "  [!] SIZE MISMATCH: expected $exp_size, got $act_size (short by $diff)"
        echo "      → proxy likely truncated mid-stream; deleting and restarting from 0 (attempt $attempt/$MAX_FILE_ATTEMPTS)"
        rm -f "$f"
      fi
    else
      wait_secs=$((attempt * 10))
      echo "  [!] curl exited non-zero (attempt $attempt/$MAX_FILE_ATTEMPTS); waiting ${wait_secs}s before retry"
      sleep "$wait_secs"
    fi
  done

  if (( ok == 0 )); then
    echo "  [X] FAILED after $MAX_FILE_ATTEMPTS attempts: $f"
    FAILED+=("$f")
  fi
done

# 5. summary + exit code
echo
echo "═══════════════════════════════════════════════════════════"
echo " Repo: $REPO  →  $DEST"
echo " total: $NUM   skipped (already complete): ${#SKIPPED[@]}   failed: ${#FAILED[@]}"
if (( ${#FAILED[@]} > 0 )); then
  echo " FAILED FILES:"
  for f in "${FAILED[@]}"; do echo "   - $f"; done
  echo "═══════════════════════════════════════════════════════════"
  echo " Re-run to retry just the failed ones (size-verified, idempotent)."
  exit 1
fi
echo " ALL FILES VERIFIED — $NUM files in $DEST"
echo " For vLLM: set VLLM_MODEL=$DEST in /data/srv/.env"
echo "═══════════════════════════════════════════════════════════"
