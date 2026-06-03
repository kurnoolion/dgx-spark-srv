# RUNBOOK — apex-spark-01 day-to-day operations

On-call reference for the DGX Spark inference + services box. Architecture and
rationale live in [README.md](README.md) and [STORAGE.md](STORAGE.md); this file
is "what do I type when X."

**Working dir for all `make` commands:** `/data/srv`
```bash
cd /data/srv
```

## At a glance

| Need | Command |
|---|---|
| Daily health check | `make health` |
| Status of everything | `make ps` |
| GPU usage (live) | `watch -n2 nvidia-smi` |
| Live vLLM monitor (GPU + KV cache + queue) | `make watch-vllm` |
| Saturation-only vLLM monitor (during load tests) | `make watch-vllm-load` |
| Tail one service | `make logs svc=vllm` |
| Restart one service | `make restart svc=qdrant` |
| Bring stack up / down | `make up` / `make down` |
| Update images + redeploy | `make deploy` |
| Shift vLLM/Ollama memory | `make rebalance util=0.50` |
| Free GPU for big Ollama job | `make vllm-stop` … `make vllm-start` |
| Check `/data` split usage | `sudo xfs_quota -x -c 'report -h' /data` |
| Check docker reclaimable space | `make prune-status` |

## Daily health check (1 minute)

```bash
make health     # services + GPU + disk + /data quotas + endpoints, PASS/WARN/FAIL
```
Evaluates everything against thresholds (disk ≥85% = FAIL, GPU ≥80C = WARN) and
**exits non-zero on any FAIL** — so the same command works from cron/monitoring.
The `/data` quota line needs sudo; run `make health` with sudo (or `sudo -v`
first) to include it, otherwise it WARNs and skips.

A vLLM "starting" WARN usually means a model is still loading (normal for large
models) — confirm with `make logs svc=vllm`. Override thresholds inline, e.g.
`DISK_WARN=90 make health`.

## Service operations

```bash
make up                 # ordered bring-up: core → vLLM (waits) → ollama/tei → gateway/apps
make down               # stop all
make restart svc=<name> # one service
make logs svc=<name>    # follow logs (Ctrl-C to stop)
make deploy             # git pull-equivalent: pull images + recreate
```
Service names: `postgres redis qdrant minio vllm ollama tei caddy prometheus grafana cadvisor node-exporter dcgm-exporter` (+ your apps from `compose.apps.yml` once you add them).

Internal endpoints are **not** published to the host (only Caddy's 443/80 are).
To probe a backend directly:
```bash
docker compose -f compose.inference.yml exec vllm curl -fsS localhost:8000/health
docker compose exec ... <svc> <cmd>
```

## Model management

**Ollama** (stays in its ~25% slice — one model loaded at a time):
```bash
docker compose -f compose.inference.yml exec ollama ollama list
docker compose -f compose.inference.yml exec ollama ollama pull qwen2.5:32b
docker compose -f compose.inference.yml exec ollama ollama rm <model>
make models             # pull the default set
```
While vLLM is up, keep Ollama models ≤ ~26 GB (≤32B-Q4 / ≤27B-Q8). For a one-off
larger model, `make vllm-stop` first, then `make vllm-start` when done.

**vLLM** serves the single model in `VLLM_MODEL`. To switch it:
```bash
# edit VLLM_MODEL in .env, then:
make restart svc=vllm   # ~minutes to load; Ollama unaffected
```
Check what's served: `docker compose -f compose.inference.yml exec vllm curl -s localhost:8000/v1/models`.

## Observability (memory monitoring)

Grafana at `https://$SITE_HOST/grafana` (admin / `GRAFANA_PASSWORD`) → **APEX —
Service Memory** dashboard: per-container memory, % of limit, host memory, GPU
framebuffer. Use it to capture real per-service RAM before finalizing the split.

Quick PromQL (Explore tab):
```promql
topk(10, container_memory_working_set_bytes{name!=""})          # hungriest services
100*(1 - node_memory_MemAvailable_bytes/node_memory_MemTotal_bytes)  # host=GPU mem %
DCGM_FI_DEV_GPU_UTIL                                             # compute saturation %
DCGM_FI_DEV_MEM_COPY_UTIL                                        # GPU mem-bandwidth %
DCGM_FI_DEV_GPU_TEMP                                             # °C
DCGM_FI_DEV_POWER_USAGE                                          # W
```
**No GPU framebuffer metric on GB10** — unified memory means the GPU has no
separate framebuffer to report. `DCGM_FI_DEV_FB_USED` does not exist on this
hardware; host memory % IS GPU memory %. The dashboard reflects this.
Community dashboards to import by ID if you want more: node 1860, cAdvisor 14282.

## Memory rebalancing (vLLM ↔ Ollama)

One lever — `VLLM_GPU_UTIL` (fraction of the full 128 GB pool). Ollama uses what's
left. See README for the conversion table.
```bash
make rebalance util=0.50   # writes .env + restarts vLLM only
```
Restarting vLLM drops its model for a couple minutes; Ollama is untouched and
picks up freed memory on its next load. **vLLM must be running before Ollama
loads a model** when you want both.

## Storage operations

**Change the home ↔ models ↔ data split** (instant, no migration):
```bash
sudo xfs_quota -x -c 'limit -p bhard=1500g models' /data
sudo xfs_quota -x -c 'limit -p bhard=1000g srv'    /data
sudo xfs_quota -x -c 'limit -p bhard=600g  home'   /data
sudo xfs_quota -x -c 'report -h -p' /data          # check usage
```

**Grow a whole LV** from the VG reserve (online):
```bash
sudo vgs                                  # check VFree
sudo lvextend -L +100G /dev/<vg>/data
sudo xfs_growfs /data                     # ext4 LVs: resize2fs /dev/<vg>/<lv>
```

**Disk/quota full** — find the hog, then either raise the ceiling or clean up:
```bash
sudo du -xh --max-depth=2 /data/models | sort -h | tail
# models full & disposable → delete unused models, or raise its quota
# srv full & durable → raise srv quota (and/or prune MinIO/old data)
```
`/data/models` is re-downloadable; never delete from `/data/srv` to free space
without confirming it's not live DB/object data.

**Docker LV (`/var/lib/docker`) full or growing** — NGC images are 15–25+ GB
each and Docker never auto-cleans:
```bash
make prune-status                         # how much is reclaimable (read-only)
make prune                                # remove old images + build cache
sudo lvextend -L +100G /dev/<vg>/docker && sudo resize2fs /dev/<vg>/docker  # if still tight
```
Log rotation + journald caps are installed once via `make install-system`
(see STORAGE.md). Schedule prune weekly:
```
30 3 * * 0  cd /data/srv && make prune >> /var/log/apex-prune.log 2>&1
```

## User management

```bash
sudo adduser <user>                       # home under /home (= /data/home, bind)
sudo xfs_quota -x -c 'limit -u bsoft=40g bhard=45g <user>' /data   # REQUIRED
sudo usermod -aG ml-users <user>          # access to /data/models/shared
sudo xfs_quota -x -c 'report -h -u' /data # who's using what
```
User quotas are **filesystem-wide on `/data`** — a user's cap counts their files
anywhere on `/data` (home + anything they own in `models/shared`), not just home.
The `home` *project* quota bounds the home tree collectively; resize it like any
split (`limit -p bhard=<size> home /data`).

Remind new users: don't override `HF_HOME` (shared cache at `/data/models/hf-cache`),
put datasets in `/data/models/shared`, keep envs off `/home` (use `uv`).

## Backups & restore

One command does everything (pg_dump + Qdrant snapshot + restic of durable
data/config). See STORAGE.md for the policy table.
```bash
make backup
```
What it does: dumps Postgres, triggers a consistent Qdrant snapshot into
`/data/srv/data/qdrant-snapshots`, archives the config, and — **only if
`RESTIC_REPO` is set in `.env`** — pushes everything off-box via restic with
retention. If `RESTIC_REPO` is blank it stages locally and warns that there is
**no DR copy yet** (current state — wire the restic target when ready).

To automate, add a cron entry once it's configured:
```
15 2 * * *  cd /data/srv && ./backup.sh >> /var/log/apex-backup.log 2>&1
```

**Restore Postgres** (DANGER — overwrites the live DB):
```bash
gunzip -c <stage>/postgres-<db>.sql.gz | docker compose exec -T postgres psql -U $PG_USER $PG_DB
```
**Restore Qdrant** — recover a collection from its snapshot file via the Qdrant
snapshot-recover API (snapshots are under `/data/srv/data/qdrant-snapshots`).

`/data/models` is **not** backed up — recover by re-pulling from the recorded
digest list, not from backup.

## Secrets

`.env` holds secrets — keep `chmod 600 root:root` on it. sops encryption is
optional for this box (see SETUP.md A8); the SED firmware lock + file mode is
the default at-rest defense. After editing:
```bash
make deploy             # or: make restart svc=<affected>
```
Rotate DB/MinIO/Grafana creds via their own tooling, then update `.env` and
restart the dependent services.

## Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| vLLM stuck "starting" / OOM at boot | `VLLM_GPU_UTIL` too high, or Ollama grabbed memory first | `make rebalance util=<lower>`; ensure vLLM starts before Ollama loads |
| Ollama OOM / won't load a model | model bigger than its free slice (vLLM holds 84 GB) | use a smaller quant, or `make vllm-stop` for the job |
| `nvidia-smi` fails / GPU not in container | driver or container-toolkit issue | `nvidia-smi` on host; `sudo systemctl restart docker`; check `nvidia-container-toolkit` |
| Image pull / model download hangs | corp proxy not reaching daemon/CLI | verify `/etc/systemd/system/docker.service.d/proxy.conf` and shell proxy env |
| Container "exec format error" / very slow | x86-only image under emulation | replace with arm64/multi-arch image |
| 502 from gateway on a route | backend down or unhealthy | `make ps`; `make logs svc=<backend>` |
| API returns unexpected 401/403 | a backend's own auth (Grafana/Postgres/MinIO) | gateway is unauthenticated — check the specific backend's logs/credentials |
| Browser cert warning | `tls internal` self-signed | expected until corp PKI certs installed; trust the CA or use VPN |
| Disk full on `/` | logs growth; or docker if not on own LV | `journalctl --vacuum-size=500M`; `make prune`; ensure `make install-system` ran (caps logs) |
| `/var/lib/docker` full | NGC image churn + build cache | `make prune`; `lvextend` from reserve; verify log rotation installed |
| `/data` full | models or RAG data over ceiling | see "Disk/quota full" above |
| Service won't start after `.env` edit | missing/blank var | `docker compose config` to validate; check `make logs svc=<name>` |

## Where things live

- Stack + config: `/data/srv` (`compose.*.yml`, `Caddyfile`, `.env`, `Makefile`)
- Durable data (backed up): `/data/srv/data/{postgres,qdrant,minio,redis,caddy}`
- Models (disposable): `/data/models/{hf-cache,ollama,shared}`
- User homes: `/home`
- Docker images: `/var/lib/docker`
- fstab backups: `/etc/fstab.bak.*`

## Escalation

For anything that risks `/data/srv` data (DB corruption, failed restore, disk
errors): stop writes (`make down`), confirm the latest backup is intact before
acting, and don't `mkfs`/`lvremove` anything. Storage changes are in
`setup-storage.sh` (dry-run first) and STORAGE.md.
