#!/usr/bin/env bash
# fix-ownership.sh — apply the /data/srv ownership + permissions model that
# lets admins pull/edit/run make without sudo, while leaving .env and the
# container bind-mounts untouched.
#
# Model:
#   Repo files           : <primary-user>:apex, dirs 2775 (sgid), files 664, execs 775
#   .env                 : root:root 600           (secrets policy — unchanged)
#   /data/srv/data/*     : NOT TOUCHED             (container UIDs — grafana=472,
#                                                   prometheus=65534, redis=999,
#                                                   open-webui=1000, etc.)
#   .git                 : shared-repository=group (multi-admin pulls don't
#                                                   create root-owned objects
#                                                   that block subsequent pulls)
#
# Also adds the primary user to the `apex` and `docker` groups if missing.
# NB: `docker` group is effectively root on the host — see README/RUNBOOK.
#
# Idempotent. Safe to re-run any number of times.
#
# Usage:
#   sudo ./fix-ownership.sh                            # $SUDO_USER as primary owner
#   sudo PRIMARY_USER=alice ./fix-ownership.sh         # explicit override
#   sudo REPO_DIR=/data/srv GROUP=apex ./fix-ownership.sh   # non-defaults

set -euo pipefail

# ── config (env-overridable) ──
REPO_DIR="${REPO_DIR:-/data/srv}"
GROUP="${GROUP:-apex}"
PRIMARY_USER="${PRIMARY_USER:-${SUDO_USER:-}}"

# ── preflight ──
if [[ $EUID -ne 0 ]]; then
    echo "ERROR: must run as root (use sudo)" >&2
    exit 1
fi
if [[ -z "$PRIMARY_USER" ]]; then
    echo "ERROR: PRIMARY_USER not set and \$SUDO_USER is empty."         >&2
    echo "       Re-run as: sudo PRIMARY_USER=<login-name> $0"           >&2
    exit 1
fi
if ! id "$PRIMARY_USER" &>/dev/null; then
    echo "ERROR: user '$PRIMARY_USER' does not exist" >&2
    exit 1
fi
if [[ ! -d "$REPO_DIR" ]]; then
    echo "ERROR: $REPO_DIR does not exist" >&2
    exit 1
fi
GIT_PRESENT=0
[[ -d "$REPO_DIR/.git" ]] && GIT_PRESENT=1

echo "==> applying ownership model"
echo "    repo:        $REPO_DIR"
echo "    primary:     $PRIMARY_USER"
echo "    group:       $GROUP"
echo "    excluded:    $REPO_DIR/data/  (container UIDs)"
echo "                 $REPO_DIR/.env   (root:root 600 — secrets policy)"
echo

# ── 1. group ──
if getent group "$GROUP" >/dev/null; then
    echo "==> group '$GROUP' exists"
else
    echo "==> creating group '$GROUP'"
    groupadd "$GROUP"
fi

# ── 2. group membership (apex + docker) ──
NEEDS_RELOGIN=0
for g in "$GROUP" docker; do
    if id -nG "$PRIMARY_USER" | tr ' ' '\n' | grep -qx "$g"; then
        echo "==> $PRIMARY_USER already in '$g'"
    else
        echo "==> adding $PRIMARY_USER to '$g'"
        usermod -aG "$g" "$PRIMARY_USER"
        NEEDS_RELOGIN=1
    fi
done

# ── 3. chown repo (excluding data/ and .env) ──
echo "==> chown $PRIMARY_USER:$GROUP  (excluding data/ and .env)"
find "$REPO_DIR" -mindepth 1 \
    \( -path "$REPO_DIR/data" -prune \) -o \
    \( -path "$REPO_DIR/.env" -prune \) -o \
    \( -exec chown "$PRIMARY_USER:$GROUP" {} + \)
chown "$PRIMARY_USER:$GROUP" "$REPO_DIR"

# ── 4. chmod dirs (2775 = sgid + group-write) ──
echo "==> chmod dirs 2775  (sgid so new files inherit '$GROUP')"
find "$REPO_DIR" -mindepth 1 \
    \( -path "$REPO_DIR/data" -prune \) -o \
    \( -type d -exec chmod 2775 {} + \)
chmod 2775 "$REPO_DIR"

# ── 5. chmod files (664 for data, 775 for executables; skip .env) ──
echo "==> chmod files 664, executables 775  (.env untouched)"
find "$REPO_DIR" -mindepth 1 \
    \( -path "$REPO_DIR/data" -prune \) -o \
    \( -path "$REPO_DIR/.env" -prune \) -o \
    \( -type f ! -perm -u+x -exec chmod 664 {} + \)
find "$REPO_DIR" -mindepth 1 \
    \( -path "$REPO_DIR/data" -prune \) -o \
    \( -path "$REPO_DIR/.env" -prune \) -o \
    \( -type f -perm -u+x -exec chmod 775 {} + \)

# ── 6. git shared-repo config ──
if [[ $GIT_PRESENT -eq 1 ]]; then
    echo "==> configuring .git for shared multi-admin access"
    # Own .git dir/files via the general chown above (already done).
    # Set core.sharedRepository so future git operations create group-shared files.
    sudo -u "$PRIMARY_USER" git -C "$REPO_DIR" config core.sharedRepository group
    # Force existing .git objects to group-writable + sgid.
    find "$REPO_DIR/.git" -type d -exec chmod 2775 {} +
    find "$REPO_DIR/.git" -type f ! -perm -u+x -exec chmod 664 {} +
    find "$REPO_DIR/.git" -type f -perm -u+x  -exec chmod 775 {} +
else
    echo "==> $REPO_DIR/.git absent — skipping shared-repo config"
fi

# ── 7. verify (or re-lock) .env ──
if [[ -f "$REPO_DIR/.env" ]]; then
    ENV_OWNER=$(stat -c '%U:%G' "$REPO_DIR/.env")
    ENV_MODE=$(stat  -c '%a'    "$REPO_DIR/.env")
    if [[ "$ENV_OWNER" == "root:root" && "$ENV_MODE" == "600" ]]; then
        echo "==> .env intact: root:root 600"
    else
        echo "WARNING: .env was $ENV_OWNER $ENV_MODE (expected root:root 600) — re-locking"
        chown root:root "$REPO_DIR/.env"
        chmod 600       "$REPO_DIR/.env"
    fi
else
    echo "==> .env absent — nothing to lock"
fi

# ── 8. summary ──
echo
echo "==> DONE. Sanity checks:"
printf '    %s\n' "$(stat -c '%U:%G %a %n' "$REPO_DIR")"
[[ -f "$REPO_DIR/Makefile" ]] && printf '    %s\n' "$(stat -c '%U:%G %a %n' "$REPO_DIR/Makefile")"
[[ -f "$REPO_DIR/.env"     ]] && printf '    %s\n' "$(stat -c '%U:%G %a %n' "$REPO_DIR/.env")"
[[ $GIT_PRESENT -eq 1     ]] && printf '    %s\n' "$(stat -c '%U:%G %a %n' "$REPO_DIR/.git/HEAD" 2>/dev/null || true)"

if [[ $NEEDS_RELOGIN -eq 1 ]]; then
    echo
    echo "==> ACTION REQUIRED: $PRIMARY_USER was added to new group(s)."
    echo "    Log out + log back in (or run: exec newgrp $GROUP) before running"
    echo "    unprivileged git/make commands."
fi
