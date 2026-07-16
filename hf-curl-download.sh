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
#   MAX_FILE_ATTEMPTS=10   per-chunk retry attempts before giving up
#   HF_CHUNK_SIZE=524288000  per-request byte size for chunked Range download
#                            (default 500 MB — small enough to slip under most
#                             corporate-proxy response-size caps that silently
#                             truncate large HTTPS responses. Auto-halves at
#                             runtime if chunks still come up short.)
#
# To point vLLM at the result, set in .env:
#   VLLM_MODEL=/data/models/local/Qwen3-32B-AWQ
#
set -uo pipefail

REPO="${1:-}"
[[ -z "$REPO" ]] && { echo "usage: $0 <user/repo> [dest_dir]"; exit 1; }
DEST="${2:-/data/models/local/${REPO##*/}}"
MAX_FILE_ATTEMPTS="${MAX_FILE_ATTEMPTS:-10}"
CHUNK_SIZE="${HF_CHUNK_SIZE:-524288000}"    # 500 MB default

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

# 4. download each file with chunked HTTP Range requests + resume + verification
#
# Every file is fetched as N chunks of CHUNK_SIZE bytes (default 500 MB) via
# HTTP Range headers. Rationale: some corporate proxies enforce a max response
# size (commonly 2-5 GB) and either silently truncate large responses or drop
# the tunnel mid-transfer — which then triggers a full-file redownload under
# the old --continue-at logic. Splitting into small ranges keeps every response
# comfortably under any reasonable cap.
#
# Resume: on restart, the local file is truncated down to the nearest chunk
# boundary and the loop picks up from there (loses at most one chunk of
# progress, never the whole file).
#
# Adaptive: if a chunk still comes up short (proxy caps below CHUNK_SIZE),
# CHUNK_SIZE auto-halves for the remaining chunks so the user doesn't have
# to guess the right value.

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

  # Fallback: if we don't know the expected size, we can't chunk safely.
  # Single-call download with the old resume logic (rare — HF tree API almost
  # always returns size, this branch is just defensive).
  if [[ "$exp_size" == "-1" || -z "$exp_size" ]]; then
    echo "  [!] expected size unknown — using single curl call (no verification)"
    if curl -fL --progress-bar --continue-at - \
         --retry 100 --retry-all-errors --retry-delay 10 --retry-max-time 0 \
         --connect-timeout 30 "${AUTH_HEADER[@]}" \
         -o "$f" "https://huggingface.co/${REPO}/resolve/main/${f}"; then
      echo "  → downloaded (unverified)"
    else
      echo "  [X] FAILED"
      FAILED+=("$f")
    fi
    continue
  fi

  total_size=$exp_size
  current_offset=$(stat -c %s "$f" 2>/dev/null || echo 0)

  # Small file that fits in a single chunk? Simple path.
  if (( total_size <= CHUNK_SIZE && current_offset == 0 )); then
    # Fall through to chunk loop — it handles a single chunk correctly too.
    :
  fi

  # Resume: align existing bytes DOWN to the nearest chunk boundary so the
  # next Range request lands cleanly on the tail.
  if (( current_offset > 0 && current_offset < total_size )); then
    aligned=$(( (current_offset / CHUNK_SIZE) * CHUNK_SIZE ))
    if (( aligned != current_offset )); then
      echo "  → resuming: truncating $current_offset → $aligned (chunk-aligned)"
      truncate -s "$aligned" "$f"
      current_offset=$aligned
    else
      echo "  → resuming from $current_offset / $total_size bytes"
    fi
  fi
  # Ensure file exists so `>>` doesn't fail on first chunk of a fresh download
  [[ -f "$f" ]] || : > "$f"

  chunk_start=$current_offset
  file_ok=1
  while (( chunk_start < total_size )); do
    chunk_end=$(( chunk_start + CHUNK_SIZE - 1 ))
    (( chunk_end >= total_size )) && chunk_end=$(( total_size - 1 ))
    expected_chunk=$(( chunk_end - chunk_start + 1 ))
    chunk_num=$(( chunk_start / CHUNK_SIZE + 1 ))
    total_chunks=$(( (total_size + CHUNK_SIZE - 1) / CHUNK_SIZE ))
    chunk_h=$(numfmt --to=iec "$expected_chunk" 2>/dev/null || echo "$expected_chunk")

    echo "  chunk $chunk_num/$total_chunks: bytes $chunk_start-$chunk_end ($chunk_h)"

    attempt=0
    chunk_ok=0
    while (( attempt < MAX_FILE_ATTEMPTS )); do
      attempt=$((attempt+1))

      # Range fetch, append to file. curl exits 0 on 206 Partial Content.
      if curl -fL --progress-bar \
           --range "${chunk_start}-${chunk_end}" \
           --retry 100 --retry-all-errors --retry-delay 10 --retry-max-time 0 \
           --connect-timeout 30 \
           "${AUTH_HEADER[@]}" \
           "https://huggingface.co/${REPO}/resolve/main/${f}" \
           >> "$f"; then

        new_size=$(stat -c %s "$f")
        actual_chunk=$(( new_size - chunk_start ))

        if (( actual_chunk == expected_chunk )); then
          chunk_ok=1
          break
        elif (( actual_chunk > expected_chunk )); then
          # Server ignored our Range and returned more than we asked for.
          # Roll back and abort — safer than trying to trim.
          echo "  [X] server returned $actual_chunk bytes for a $expected_chunk-byte range — Range not honored?"
          truncate -s "$chunk_start" "$f"
          break
        else
          echo "  [!] chunk short: got $actual_chunk / $expected_chunk bytes (attempt $attempt/$MAX_FILE_ATTEMPTS)"
          truncate -s "$chunk_start" "$f"

          # Adaptive shrink: if the proxy is capping below our CHUNK_SIZE,
          # halve for the retry AND for all subsequent chunks.
          if (( actual_chunk > 0 )); then
            new_size_hint=$(( actual_chunk / 2 ))
            (( new_size_hint < 65536 )) && new_size_hint=65536      # floor 64 KB
            if (( new_size_hint < CHUNK_SIZE )); then
              new_h=$(numfmt --to=iec "$new_size_hint" 2>/dev/null || echo "$new_size_hint")
              echo "      → proxy appears to cap ~$actual_chunk bytes; reducing CHUNK_SIZE to $new_h for remaining chunks"
              CHUNK_SIZE=$new_size_hint
              chunk_end=$(( chunk_start + CHUNK_SIZE - 1 ))
              (( chunk_end >= total_size )) && chunk_end=$(( total_size - 1 ))
              expected_chunk=$(( chunk_end - chunk_start + 1 ))
            fi
          fi
        fi
      else
        wait_secs=$((attempt * 10))
        echo "  [!] chunk curl failed (attempt $attempt/$MAX_FILE_ATTEMPTS); rolling back, waiting ${wait_secs}s"
        truncate -s "$chunk_start" "$f"
        sleep "$wait_secs"
      fi
    done

    if (( chunk_ok == 0 )); then
      echo "  [X] chunk FAILED after $MAX_FILE_ATTEMPTS attempts at offset $chunk_start"
      file_ok=0
      break
    fi

    chunk_start=$(( chunk_end + 1 ))
  done

  if (( file_ok == 1 )); then
    final_size=$(stat -c %s "$f")
    if (( final_size == total_size )); then
      echo "  → OK ($final_size bytes verified via chunked download)"
    else
      echo "  [X] FINAL SIZE MISMATCH: got $final_size, expected $total_size"
      FAILED+=("$f")
    fi
  else
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
