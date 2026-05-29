#!/usr/bin/env bash
#
# install-system.sh — host hygiene config (invoked by `make install-system`)
#
# Installs Docker container-log rotation and a journald size cap so logs can't
# fill the root / docker LVs.
#
# SAFETY: the Docker daemon.json is MERGED, not overwritten — the NVIDIA
# container runtime config (added by nvidia-ctk) lives in the same file, and
# clobbering it would break GPU containers. Existing file is backed up first.
#
set -euo pipefail
cd "$(dirname "$0")"
[[ $EUID -eq 0 ]] || { echo "run as root (sudo)"; exit 1; }

DST=/etc/docker/daemon.json
mkdir -p /etc/docker

# ── Docker daemon.json (merge log-opts/data-root, preserve everything else) ──
if [[ -f "$DST" ]]; then
  cp -a "$DST" "$DST.bak.$(date +%Y%m%d-%H%M%S)"
  if command -v jq >/dev/null; then
    tmp=$(mktemp)
    # right-hand (ours) wins on conflicting keys; nvidia "runtimes" etc. preserved
    jq -s '.[0] * .[1]' "$DST" system/daemon.json > "$tmp" && mv "$tmp" "$DST"
    echo "[*] merged log rotation into $DST (existing keys preserved)"
  else
    echo "[!] jq not installed — refusing to overwrite $DST (would wipe NVIDIA runtime)."
    echo "    install jq, or manually merge these keys into $DST:"
    sed 's/^/      /' system/daemon.json
    exit 1
  fi
else
  cp system/daemon.json "$DST"
  echo "[*] installed $DST"
  echo "[!] NOTE: if the NVIDIA runtime wasn't configured yet, run: sudo nvidia-ctk runtime configure"
fi

# ── journald cap ──
install -D -m644 system/journald-apex.conf /etc/systemd/journald.conf.d/apex.conf
systemctl restart systemd-journald
echo "[*] journald cap installed + applied"

# ── apply docker config (restarts containers) ──
echo "[!] Docker log rotation needs a docker restart (restarts ALL containers),"
echo "    and applies to NEWLY created containers — recreate with 'make up' after."
read -r -p "    restart docker now? [y/N] " a
if [[ "${a,,}" == "y" ]]; then
  systemctl restart docker && echo "[*] docker restarted"
else
  echo "    skipped — later: sudo systemctl restart docker && (cd /data/srv && make up)"
fi
echo "[*] done."
