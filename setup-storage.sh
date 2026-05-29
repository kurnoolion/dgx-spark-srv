#!/usr/bin/env bash
#
# setup-storage.sh — apex-spark-01 storage bring-up (see STORAGE.md)
#
# Creates the /home and /data LVs, makes filesystems, mounts them, sets up the
# XFS project-quota "split" between /data/models and /data/srv, enables /home
# quotas, and creates the compose bind-mount dirs. Optionally relocates
# /var/lib/docker onto its own LV.
#
# SAFETY MODEL:
#   * dry-run by default — prints the plan and exits; needs --apply to act
#   * never mkfs an LV that already has a filesystem (refuses, doesn't clobber)
#   * never lvcreate an LV that already exists (skips)
#   * never shrinks a live root — bails if the VG has no free space
#   * backs up /etc/fstab before editing; fstab edits are idempotent
#
# Usage:
#   sudo ./setup-storage.sh                 # dry run (plan only)
#   sudo ./setup-storage.sh --apply         # do it (asks for confirmation)
#   sudo ./setup-storage.sh --apply --yes   # do it, no prompt
#   sudo ./setup-storage.sh --apply --move-docker   # also relocate /var/lib/docker
#   VG=myvg sudo -E ./setup-storage.sh --apply      # force a specific VG
#
set -euo pipefail

# ─────────────────────────── configurable sizes ───────────────────────────
# ALL SIZES BELOW ARE IN GiB (binary, 2^30), matching what LVM/lvcreate `-L NG`
# and xfs_quota `bhard=Ng` use. The preflight reads VG free space with
# `vgs --units G` for the same convention — keep all comparisons GiB-on-GiB.
VG="${VG:-}"                       # auto-detected if empty
SIZE_DATA_GB="${SIZE_DATA_GB:-2900}"        # GiB. one volume: home + models + srv
SIZE_DOCKER_GB="${SIZE_DOCKER_GB:-300}"     # GiB.
VG_KEEP_FREE_GB="${VG_KEEP_FREE_GB:-150}"   # GiB. leave unallocated as grow headroom
QUOTA_HOME="${QUOTA_HOME:-400g}"            # /data/home   ceiling (the split)
QUOTA_MODELS="${QUOTA_MODELS:-1800g}"       # /data/models ceiling (the split)
QUOTA_SRV="${QUOTA_SRV:-700g}"              # /data/srv     ceiling (the split)
HOME_USER_SOFT="${HOME_USER_SOFT:-40g}"
HOME_USER_HARD="${HOME_USER_HARD:-45g}"
REDIS_UID="${REDIS_UID:-999}"               # redis:7 runtime uid
ML_GROUP="${ML_GROUP:-ml-users}"            # group for the shared models dropzone

APPLY=0; ASSUME_YES=0; MOVE_DOCKER=0
for arg in "$@"; do case "$arg" in
  --apply) APPLY=1 ;;
  --yes) ASSUME_YES=1 ;;
  --move-docker) MOVE_DOCKER=1 ;;
  -h|--help) grep -E '^#( |$)' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
  *) echo "unknown arg: $arg" >&2; exit 2 ;;
esac; done

# ───────────────────────────── helpers ────────────────────────────────────
RED=$'\e[31m'; GRN=$'\e[32m'; YEL=$'\e[33m'; CLR=$'\e[0m'
info(){ echo "${GRN}[*]${CLR} $*"; }
warn(){ echo "${YEL}[!]${CLR} $*"; }
die(){ echo "${RED}[x]${CLR} $*" >&2; exit 1; }
step(){ echo; echo "${GRN}── $* ──${CLR}"; }

[[ $EUID -eq 0 ]] || die "run as root (sudo)."

for t in lvs lvcreate vgs mkfs.xfs mkfs.ext4 blkid xfs_quota; do
  command -v "$t" >/dev/null || die "missing tool: $t  (install lvm2 / xfsprogs)"
done

# ───────────────────────────── preflight ──────────────────────────────────
step "Preflight"
if [[ -z "$VG" ]]; then
  mapfile -t vgs < <(vgs --noheadings -o vg_name 2>/dev/null | awk '{$1=$1;print}')
  [[ ${#vgs[@]} -eq 1 ]] || die "found ${#vgs[@]} VGs (${vgs[*]:-none}); set VG=<name> explicitly."
  VG="${vgs[0]}"
fi
vgs "$VG" >/dev/null 2>&1 || die "volume group '$VG' not found."

vfree_gb=$(vgs --noheadings -o vg_free --units G --nosuffix "$VG" | awk '{printf "%d",$1}')
need_gb=$(( SIZE_DATA_GB + VG_KEEP_FREE_GB ))
(( MOVE_DOCKER )) && need_gb=$(( need_gb + SIZE_DOCKER_GB ))
info "VG '$VG' free: ${vfree_gb} GiB ; this plan needs: ${need_gb} GiB (incl. ${VG_KEEP_FREE_GB} GiB reserve)"
if (( vfree_gb < need_gb )); then
  die "not enough free space in VG. Root likely fills the disk — you must reinstall
       DGX OS with a smaller root, or add a disk, before this layout fits.
       (This script will NOT shrink a live root.)"
fi

# ───────────────────────────── plan ───────────────────────────────────────
step "Plan"
cat <<PLAN
  VG ................. $VG  (free ${vfree_gb} GiB)
  create LV data ..... ${SIZE_DATA_GB} GiB  XFS  -> /data  (pquota,uquota)
  bind mount ......... /data/home -> /home
$( ((MOVE_DOCKER)) && echo "  create LV docker ... ${SIZE_DOCKER_GB} GiB  ext4  -> /var/lib/docker (migrate existing)" || echo "  docker ............. left on root (use --move-docker to relocate)" )
  /data split (XFS project quota, adjustable later):
      home ........... bhard=${QUOTA_HOME}
      models ......... bhard=${QUOTA_MODELS}
      srv ............ bhard=${QUOTA_SRV}
  /home per-user quota ${HOME_USER_SOFT} soft / ${HOME_USER_HARD} hard (uid>=1000; fs-wide on /data)
  VG reserve ......... ${VG_KEEP_FREE_GB} GiB left unallocated
PLAN

if (( ! APPLY )); then
  warn "DRY RUN — nothing changed. Re-run with --apply to execute."
  exit 0
fi

if (( ! ASSUME_YES )); then
  echo; read -r -p "Type 'apply' to proceed (this formats new LVs): " ans
  [[ "$ans" == "apply" ]] || die "aborted."
fi

# ───────────────────────────── LV creation ────────────────────────────────
# create_lv <name> <size_gb> <ext4|xfs> <mountpoint> <fstab_opts> <dump> <pass>
create_lv() {
  local name=$1 size=$2 fs=$3 mnt=$4 opts=$5 dump=$6 pass=$7
  local dev="/dev/$VG/$name"
  step "LV: $name -> $mnt ($fs)"

  if lvs "$VG/$name" >/dev/null 2>&1; then
    warn "LV $name already exists — skipping lvcreate"
  else
    info "lvcreate -n $name -L ${size}G $VG"
    lvcreate -y -n "$name" -L "${size}G" "$VG"
  fi

  if blkid "$dev" >/dev/null 2>&1; then
    warn "$dev already has a filesystem — skipping mkfs (SAFETY)"
  else
    info "mkfs.$fs $dev"
    if [[ $fs == xfs ]]; then mkfs.xfs -q "$dev"; else mkfs.ext4 -q "$dev"; fi
  fi

  mkdir -p "$mnt"
  local uuid; uuid=$(blkid -s UUID -o value "$dev")
  if grep -qE "^[^#]*[[:space:]]${mnt//\//\\/}[[:space:]]" /etc/fstab; then
    warn "fstab already has an entry for $mnt — leaving it"
  else
    info "adding fstab entry for $mnt"
    printf 'UUID=%s  %s  %s  %s  %s %s\n' "$uuid" "$mnt" "$fs" "$opts" "$dump" "$pass" >> /etc/fstab
  fi
}

step "Back up /etc/fstab"
cp -a /etc/fstab "/etc/fstab.bak.$(date +%Y%m%d-%H%M%S)"
info "saved."

create_lv data "$SIZE_DATA_GB" xfs /data "defaults,pquota,uquota" 0 2

step "Mount /data"
mount -a
findmnt /data >/dev/null || die "/data did not mount — check /etc/fstab"
info "/data mounted."

step "Bind /data/home -> /home"
mkdir -p /data/home
# migrate any existing /home content onto /data BEFORE binding (else it's hidden)
if ! findmnt /home >/dev/null 2>&1 && [[ -n "$(ls -A /home 2>/dev/null)" ]]; then
  if [[ -z "$(ls -A /data/home 2>/dev/null)" ]]; then
    command -v rsync >/dev/null || die "rsync needed to migrate existing /home"
    info "migrating existing /home -> /data/home"
    rsync -aHAX /home/ /data/home/
  else
    warn "/data/home not empty AND /home has content — skipping auto-migrate; reconcile manually"
  fi
fi
if grep -qE "^[^#]*[[:space:]]/home[[:space:]]" /etc/fstab; then
  warn "fstab already has a /home entry — leaving it"
else
  info "adding /home bind mount to fstab"
  printf '/data/home  /home  none  bind  0 0\n' >> /etc/fstab
fi
mount -a
findmnt /home >/dev/null || die "/home bind did not mount — check /etc/fstab"
info "/home -> /data/home active."

# ───────────────────────── bind-mount directories ─────────────────────────
step "Create service + model directories"
mkdir -p /data/srv/data/{postgres,redis,qdrant,qdrant-snapshots,minio,caddy,caddy-config,prometheus,grafana}
mkdir -p /data/models/{hf-cache,ollama,shared}
chown -R "${REDIS_UID}:${REDIS_UID}" /data/srv/data/redis   # redis runs as uid 999
chown -R 65534:65534 /data/srv/data/prometheus             # prometheus runs as nobody
chown -R 472:472     /data/srv/data/grafana                # grafana runs as uid 472
getent group "$ML_GROUP" >/dev/null || groupadd "$ML_GROUP"
# Make ALL shared model dirs writable by ml-users: hf-cache + ollama models + the
# user dropzone. setgid (2775) so new files inherit ml-users group automatically.
chgrp "$ML_GROUP" /data/models/{shared,hf-cache,ollama}
chmod 2775         /data/models/{shared,hf-cache,ollama}
info "directories ready."

# ───────────────────────── /data project quotas ───────────────────────────
step "XFS project quotas on /data (home / models / srv split)"
grep -q '/data/home' /etc/projects 2>/dev/null || \
  printf '10:/data/models\n20:/data/srv\n30:/data/home\n' >> /etc/projects
grep -q '^home:'     /etc/projid   2>/dev/null || \
  printf 'models:10\nsrv:20\nhome:30\n' >> /etc/projid
xfs_quota -x -c 'project -s models' -c 'project -s srv' -c 'project -s home' /data
xfs_quota -x -c "limit -p bhard=${QUOTA_HOME}   home"   /data
xfs_quota -x -c "limit -p bhard=${QUOTA_MODELS} models" /data
xfs_quota -x -c "limit -p bhard=${QUOTA_SRV}    srv"    /data
info "split set: home=${QUOTA_HOME}, models=${QUOTA_MODELS}, srv=${QUOTA_SRV}"
info "  change later: xfs_quota -x -c 'limit -p bhard=<size> <home|models|srv>' /data"

# ─────────────────────── /data per-user (home) quotas ─────────────────────
step "XFS per-user quotas on /data (home allowance)"
warn "user quotas are FILESYSTEM-WIDE: they count a user's files anywhere on /data"
applied=0
while IFS=: read -r user _ uid _ _ home _; do
  [[ $uid -ge 1000 && $uid -lt 65000 && $home == /home/* ]] || continue
  xfs_quota -x -c "limit -u bsoft=${HOME_USER_SOFT} bhard=${HOME_USER_HARD} $user" /data && applied=$((applied+1))
done < <(getent passwd)
info "per-user quota (${HOME_USER_SOFT}/${HOME_USER_HARD}) applied to $applied existing user(s)."
info "  new users later: xfs_quota -x -c 'limit -u bsoft=${HOME_USER_SOFT} bhard=${HOME_USER_HARD} <user>' /data"

# ──────────────────────── optional: move docker ───────────────────────────
if (( MOVE_DOCKER )); then
  step "Relocate /var/lib/docker onto its own LV (RISKIEST STEP)"
  if findmnt /var/lib/docker >/dev/null; then
    warn "/var/lib/docker is already a mountpoint — skipping migration"
  else
    info "stopping docker"
    systemctl stop docker docker.socket 2>/dev/null || true
    create_lv docker "$SIZE_DOCKER_GB" ext4 /mnt/_dockerlv "defaults" 0 2
    # we mounted it temporarily at /mnt/_dockerlv via create_lv's mount -a? No — mount it now:
    mount -a
    info "copying existing docker data -> new LV"
    rsync -aHAX --numeric-ids /var/lib/docker/ /mnt/_dockerlv/
    info "swapping mountpoint to /var/lib/docker"
    umount /mnt/_dockerlv
    sed -i 's#[[:space:]]/mnt/_dockerlv[[:space:]]#  /var/lib/docker  #' /etc/fstab
    mv /var/lib/docker /var/lib/docker.old
    mkdir -p /var/lib/docker
    mount -a
    rmdir /mnt/_dockerlv 2>/dev/null || true
    info "starting docker"
    systemctl start docker
    docker info >/dev/null && info "docker healthy on new LV. Old data kept at /var/lib/docker.old — remove after verifying."
  fi
fi

# ───────────────────────────── verify ─────────────────────────────────────
step "Verify"
df -hT /data $( ((MOVE_DOCKER)) && echo /var/lib/docker )
findmnt /home >/dev/null && info "/home is bound to /data/home"
echo
xfs_quota -x -c 'report -h -p' /data || true       # project: home/models/srv
echo
info "Storage bring-up complete."
cat <<NEXT

Next:
  1. Decide & apply encryption (SED lock or LUKS on /data, /home) — see STORAGE.md.
  2. Set HF_HOME=/data/hf-cache system-wide (/etc/profile.d/) and point it at
     /data/models/hf-cache  (symlink or set HF_HOME=/data/models/hf-cache).
  3. cd /data/srv && cp .env.example .env  (fill + sops-encrypt) && make up
NEXT
