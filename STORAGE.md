# Storage layout — apex-spark-01

DGX Spark, 4 TB NVMe (~3.5 TB usable after install), single self-encrypting SSD.
Strategy: LVM logical volumes for the things that need hard isolation; **home,
models, and service-data all live on one shared `/data` XFS volume, divided by
adjustable XFS project quotas** — so any of the three can be expanded or shrunk
in seconds, in either direction, with no data movement and no downtime. (XFS/ext4
don't shrink, so fixed volumes could only ever grow — quotas let space flow.)

## Partition / LV layout

| Mount | Size | FS | Purpose | Backed up? |
|---|---|---|---|---|
| `/` | 150 GB | ext4 | OS, CUDA, drivers, docker engine | config only |
| `/var/lib/docker` | 300 GB | ext4 | images, build cache, overlay2 | no |
| `/data` | ~2.9 TB | **XFS + pquota + uquota** | shared pool: home + models + service data | partial |
| `/home` | — | (bind of `/data/home`) | user accounts | **yes** |
| *(VG unallocated)* | ~150 GB | — | growth headroom for any LV | — |
| swap | — | — | disabled (optional zram 8–16 GB) | — |

Only `/` and `/var/lib/docker` keep hard physical isolation. `/data` is one XFS
volume holding `home/`, `models/`, and `srv/`, each bounded by an adjustable
project-quota ceiling. `/home` is a **bind mount** of `/data/home` so user paths
are unchanged. Keep `home + models + srv caps ≤ /data size` for a hard guarantee,
or overcommit deliberately to let them share first-come.

### Expected: `df` shows ~58 GiB "used" on an empty `/data` — this is normal

Right after `setup-storage.sh --apply`, `df -hT /data` reports ~58 GiB used even
though `du`, `xfs_db freesp`, and `xfs_quota report` all show only ~1–3 GiB of
real content. **This is not a bug or a leak.** It's the **per-AG reservation
that XFS holds back for the `reflink` + `rmap` btrees** (both enabled by default
in modern `mkfs.xfs`) so those metadata btrees can grow as files are shared/CoW'd.

Math on this box: 4 AGs × ~14 GiB reservation each = ~58 GiB hidden.

**Implications:**
- **Effective usable capacity is ~2842 GiB**, not 2900 GiB.
- The default project-quota caps (home 400 + models 1800 + srv 700 = 2900 GiB)
  are very slightly over-committed against effective capacity. In practice this
  only matters if all three projects simultaneously near their hard limits —
  `make health` and the disk-usage threshold will warn long before that. Adjust
  one quota down if you want a strict guarantee.
- **Don't try to "fix" it.** Removing the reservation requires recreating the
  filesystem with `mkfs.xfs -m reflink=0,rmapbt=0`, which loses reflink (useful
  for fast COW snapshots of model files / DB clones). Not worth ~2% capacity.

## The three-way split (XFS project quotas)

### One-time setup
```bash
# fstab:
#   /dev/<vg>/data  /data  xfs   defaults,pquota,uquota  0 0
#   /data/home      /home  none  bind                    0 0
printf '10:/data/models\n20:/data/srv\n30:/data/home\n' | sudo tee -a /etc/projects
printf 'models:10\nsrv:20\nhome:30\n'                   | sudo tee -a /etc/projid
sudo xfs_quota -x -c 'project -s models' -c 'project -s srv' -c 'project -s home' /data

# initial ceilings — THIS is the split (sums to 2900; adjust freely):
sudo xfs_quota -x -c 'limit -p bhard=1800g models' /data
sudo xfs_quota -x -c 'limit -p bhard=700g  srv'    /data
sudo xfs_quota -x -c 'limit -p bhard=400g  home'   /data
```
`project -s` sets the project-inherit flag, so new files (incl. new users' homes
under `/data/home`) automatically count against the right project.

### Change any split later (instant, reversible, no migration)
```bash
sudo xfs_quota -x -c 'limit -p bhard=600g  home'   /data   # grow home
sudo xfs_quota -x -c 'limit -p bhard=1600g models' /data   # shrink models
```

### Per-user caps within home
User quotas on XFS are **filesystem-wide**, so a user's cap counts everything
they own across `/data` (home + anything in `models/shared`), not just home:
```bash
sudo xfs_quota -x -c 'limit -u bsoft=40g bhard=45g <user>' /data
```
The `home` project quota bounds the home tree *collectively*; per-user quotas
keep one user from consuming the whole home allowance.

> **Gotcha: the 40G/45G default is too low for operators pulling large models.**
> Qwen3-32B-AWQ (~19 GB), Qwen3-VL-32B-Instruct-FP8 (~32 GB), and similar
> weights are downloaded to `/data/models/local/<name>/` but their files are
> **owned by the operator** — so they count against the user quota AND the
> `models` project quota in parallel. A single 32 GB VL model already exceeds
> the default cap. Symptoms are misleading: `hf-curl-download.sh` reports
> `curl: (23) Failure writing output to destination` mid-transfer and grinds
> in `--retry 100` for hours while `df` shows the FS 3% full. `dd
> conv=fsync` exposes it as `Disk quota exceeded`. **Before large pulls,**
> raise the operator account's cap:
> ```bash
> sudo xfs_quota -x -c 'limit -u bsoft=450g bhard=500g <operator>' /data
> ```
> Consider bumping the default in `setup-storage.sh` if this comes up for
> more than one user on the box.

### Check usage
```bash
sudo xfs_quota -x -c 'report -h -p' /data     # project (home/models/srv) usage
sudo xfs_quota -x -c 'report -h -u' /data     # per-user usage
```

> XFS project and group quotas are mutually exclusive per filesystem — fine here:
> we use project + user, not group.

## What lives where

### `/data/srv` — durable, backed up (project `srv`)
```
/data/srv/
├── docker-compose.yml  compose.*.yml  Caddyfile  Makefile  .env   (the stack)
├── apps/
└── data/                                          (← backup target)
    ├── postgres/  qdrant/  qdrant-snapshots/  minio/  redis/  caddy/  caddy-config/
    └── prometheus/  grafana/                  (observability)
```
Service data is **bind-mounted** here. Create dirs with `make init`.

### `/data/models` — disposable, not backed up (project `models`)
```
/data/models/
├── hf-cache/    HF_HOME — shared HuggingFace cache (set system-wide)
├── ollama/      Ollama model blobs
└── shared/      group-writable (ml-users) dropzone for datasets/models
```
Re-downloadable, so excluded from backup. **Record model digests** for repro.

### `/data/home` (= `/home`) — user accounts, backed up (project `home`)
Bind-mounted to `/home`. Per-user XFS quotas (default 40/45 GB) prevent one user
filling the home allowance. Keep home lean: datasets → `/data/models/shared`,
shared `HF_HOME`, `uv` instead of fat venvs.

### Not on `/data`
- Docker images + build cache → `/var/lib/docker`
- System logs → `/` (journald) or shipped to corp SIEM

**Docker space hygiene (important — NGC images are 15–25+ GB and Docker never
self-cleans).** Run `make install-system` once to install container-log rotation
(`50m × 3`, merged into `daemon.json` *without* touching the NVIDIA runtime) and
a journald cap (`SystemMaxUse=2G`). Then `make prune` (schedule weekly) reclaims
old images + build cache. If `/var/lib/docker` still gets tight, grow it from the
VG reserve: `sudo lvextend -L +100G /dev/<vg>/docker && sudo resize2fs /dev/<vg>/docker`.
Keeping it a fixed LV (not in the `/data` quota pool) is deliberate — image churn
stays hard-isolated from model/RAG data.

## Backup policy

| Source | Method | Schedule | Retention |
|---|---|---|---|
| `/data/srv/data/postgres` | `pg_dump` + WAL archive → MinIO | nightly | 14 days |
| `/data/srv/data/qdrant-snapshots` | Qdrant snapshot API | daily | 14 days |
| `/data/srv/data/minio` | restic → corp target | daily | 30 days |
| `/data/srv/*.yml`, `.env`, `Caddyfile` | restic (restic encrypts the archive — `.env` itself optionally sops-encrypted, see SETUP.md A8) | daily | 30 days |
| `/data/srv/data/grafana` | restic (dashboards/settings) | daily | 30 days |
| `/data/home` (`/home`) | restic → corp target | daily | 30 days |
| `/data/srv/data/prometheus` | **none** — metrics TSDB, regenerates | — | — |
| `/data/models` | **none** — record digests instead | — | — |

`make backup` runs pg_dump + Qdrant snapshot + restic; see RUNBOOK.md. Don't
raw-copy live Postgres files — use `pg_dump`/WAL.

## Encryption (decide before data lands)

The NVMe is self-encrypting (SED). An *unlocked* SED protects nothing at rest —
confirm it's locked with a key, or put **LUKS** on `/data`. If MNO/customer
compliance data will live here, this is required, and retrofitting onto a
populated volume means a migration. Decide now.

## Growing storage

Two levers:

- **Rebalance home vs. models vs. service data** → change the project-quota
  ceilings (instant, any direction) — see "Change any split" above. No LVM.
- **Grow the whole `/data` LV** (or `/`, `/var/lib/docker`) → pull from the VG
  reserve, online:
  ```bash
  sudo vgs                                  # check VFree
  sudo lvextend -L +100G /dev/<vg>/data
  sudo xfs_growfs /data                     # ext4 LVs: resize2fs /dev/<vg>/<lv>
  ```
  XFS/ext4 grow online; neither shrinks safely — only ever grow, from the reserve.

## First-time setup checklist

> Steps 2–4 and 7 are automated by **`setup-storage.sh`** (dry-run by default;
> `sudo ./setup-storage.sh --apply`). Encryption (step 5) is intentionally manual.

1. Confirm layout: `lsblk -f`, `df -h`, `sudo vgs && sudo lvs`
2. Create the `data` LV; make it XFS with `pquota,uquota`
3. fstab: mount `/data`, then bind `/data/home` → `/home`; `mount -a`
4. Set the three project ceilings + per-user quotas (see "One-time setup")
5. Decide & apply encryption (SED lock or LUKS) — before any data
6. Set Docker `data-root` to `/var/lib/docker` if relocating
7. `make init` (creates bind-mount dirs incl. `/data/home`) → `make up`
