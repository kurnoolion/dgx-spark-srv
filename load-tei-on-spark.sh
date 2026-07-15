#!/usr/bin/env bash
#
# load-tei-on-spark.sh — load the TEI arm64 image tarball (built on WSL via
# build-tei-arm64.sh) into the spark's docker. Counterpart to that build script.
#
# Usage:
#   ./load-tei-on-spark.sh                              # load /tmp/tei-cpu-arm64.tar
#   ./load-tei-on-spark.sh /path/to/tei.tar             # load from custom path
#   ./load-tei-on-spark.sh --restart                    # also restart tei service
#   ./load-tei-on-spark.sh --restart --cleanup          # restart + delete tarball after
#
# Idempotent — re-loading an already-present image just replaces the layers.
#
set -euo pipefail
cd "$(dirname "$0")"

TAR="/tmp/tei-cpu-arm64.tar"
RESTART=0
CLEANUP=0
EXPECTED_IMAGE="${TEI_IMAGE:-local/tei:cpu-arm64}"

for arg in "$@"; do
  case "$arg" in
    --restart)  RESTART=1 ;;
    --cleanup)  CLEANUP=1 ;;
    -h|--help)
      sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *)
      [[ -f "$arg" ]] && TAR="$arg" || { echo "ERROR unknown arg or missing file: $arg" >&2; exit 2; }
      ;;
  esac
done

# ── preflight ──
[[ -f "$TAR" ]] || { echo "ERROR tarball not found: $TAR" >&2; echo "  build it off-box (docker + buildx + qemu-user on any linux host)"; echo "  then transfer the tarball to this host at $TAR"; echo "  see SETUP.md Part B2-build fallback for the full recipe"; exit 1; }
command -v docker >/dev/null || { echo "ERROR docker not installed"; exit 1; }
docker info >/dev/null 2>&1 || { echo "ERROR can't reach docker daemon (in docker group? newgrp docker)"; exit 1; }

SIZE=$(du -h "$TAR" | cut -f1)
echo "[*] loading $TAR ($SIZE) into docker"

# ── load ──
LOADED_NAME=$(docker load -i "$TAR" 2>&1 | tee /dev/stderr | awk -F': ' '/^Loaded image: / {print $2; exit}')

if [[ -z "$LOADED_NAME" ]]; then
  echo "ERROR docker load completed but no image name reported"
  echo "  raw output above; check 'docker images -a' for an untagged image"
  exit 1
fi
echo "[*] loaded as: $LOADED_NAME"

# ── verify it matches what compose expects ──
if [[ "$LOADED_NAME" != "$EXPECTED_IMAGE" ]]; then
  echo "[!] WARN: loaded image is '$LOADED_NAME' but compose expects '$EXPECTED_IMAGE'"
  echo "    re-tagging so compose finds it:"
  docker tag "$LOADED_NAME" "$EXPECTED_IMAGE"
fi

docker images "$EXPECTED_IMAGE" --format 'table {{.Repository}}\t{{.Tag}}\t{{.ID}}\t{{.Size}}'

# ── optionally restart the tei service ──
if (( RESTART == 1 )); then
  echo
  echo "[*] restarting tei service to pick up the new image"
  if docker compose -f compose.inference.yml ps tei 2>/dev/null | grep -q tei; then
    docker compose -f compose.inference.yml up -d --no-deps tei
    echo "[*] tei restart issued; check: make logs svc=tei"
  else
    echo "[!] tei container not found — run 'make up' to start it"
  fi
fi

# ── optionally cleanup ──
if (( CLEANUP == 1 )); then
  echo "[*] removing tarball $TAR"
  rm -f "$TAR"
fi

echo
echo "[*] DONE"
echo "  next: cd /data/srv && make up    (or 'make restart svc=tei' if stack is already up)"
echo "  verify after start: docker compose -f compose.inference.yml exec tei curl -fsS localhost:80/health"
