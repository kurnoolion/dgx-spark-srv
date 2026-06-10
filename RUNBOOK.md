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

**vLLM** serves the single model in `VLLM_MODEL`. The compose file auto-
resolves three forms — `Qwen3-32B-AWQ` (bare name; expands to
`/data/local/Qwen3-32B-AWQ`), `/data/local/Qwen3-32B-AWQ` (absolute path),
or `Qwen/Qwen3-32B-AWQ` (HF repo ID). To switch:
```bash
# edit VLLM_MODEL in .env (bare-name form preferred), then:
make restart svc=vllm   # ~minutes to load; Ollama unaffected
```
Check what's served and the **short name API clients must use**:
```bash
docker compose -f compose.inference.yml exec vllm curl -s localhost:8000/v1/models \
  | python3 -m json.tool
# The "id" field is the name to pass as `"model": "..."` in API requests.
```

For **thinking-style models** (Qwen3, DeepSeek-R1), set `VLLM_REASONING_PARSER`
in `.env` (`qwen3` or `deepseek_r1`) so vLLM separates `<think>...</think>`
content into `message.reasoning_content`. Without this, the thinking trace
leaks into `message.content` and shows up in NORA/SIRA/Open-WebUI responses.
Leave blank when serving a non-reasoning model — some refuse the flag.
(Older vLLM builds (≤0.7) required `--enable-reasoning` alongside the
parser; vLLM 0.8+/NGC 25.11+ dropped that flag. The compose file uses the
0.8+ syntax. If you ever roll back to an older image, add `--enable-reasoning`
back to the conditional in `compose.inference.yml`.)
Verify after a model swap (the model name is whatever `/v1/models` reports —
basename for path/bare-name forms, full HF repo ID for HF lookups):
```bash
MNAME=$(docker compose -f compose.inference.yml exec -T vllm \
        curl -s localhost:8000/v1/models | python3 -c 'import sys,json;print(json.load(sys.stdin)["data"][0]["id"])')
docker compose -f compose.inference.yml exec -T vllm \
  curl -s http://localhost:8000/v1/chat/completions -H 'Content-Type: application/json' \
  -d "{\"model\":\"$MNAME\",\"messages\":[{\"role\":\"user\",\"content\":\"why is the sky blue?\"}],\"max_tokens\":128}" \
  | python3 -m json.tool
# message.content should be the answer only; thinking lives in reasoning_content
```

**TEI reranker** (`tei-reranker` service, route `/rerank/*`) runs in its own
container using the same TEI image as the embedder but pointed at a
cross-encoder model. Runs on GPU (~4 GB) alongside the embedder — accounted
for by `VLLM_GPU_UTIL=0.58` (see README "GPU memory budget"). Default model
`bge-reranker-large` (~568M params). Picking a new reranker means clearing
**two** hurdles:

  - **ONNX export on HF** — TEI's ORT backend loads `onnx/model.onnx`.
    `curl -sL 'https://huggingface.co/api/models/<org>/<model>/tree/main?recursive=true' | grep onnx`
  - **`model_type` field in config.json** — TEI's parser is strict and does
    NOT follow `auto_map` (`trust_remote_code=True`-style configs are rejected).
    `curl -sL 'https://huggingface.co/<org>/<model>/raw/main/config.json' | python3 -c 'import sys,json; c=json.load(sys.stdin); print("model_type:", c.get("model_type","MISSING"))'`

Models we tested and rejected (kept here so we don't relitigate):
  - `BAAI/bge-reranker-v2-m3` — fails hurdle 1 (PyTorch safetensors only).
  - `jinaai/jina-reranker-v2-base-multilingual` — fails hurdle 2 (uses
    `auto_map` + custom `XLMRobertaFlashConfig`, no bare `model_type`).

Verified drop-in alternatives that clear both:
  - `BAAI/bge-reranker-large` *(default)* — ~568M, xlm-roberta, multilingual.
  - `BAAI/bge-reranker-base` — ~278M, xlm-roberta, smaller/faster.
  - `mixedbread-ai/mxbai-rerank-large-v1` — ~435M, deberta-v2, strong English.
  - `mixedbread-ai/mxbai-rerank-base-v1` — ~184M, deberta-v2.
Quick test:
```bash
curl -sk https://apex-spark-01.local/rerank/rerank \
  -H 'Content-Type: application/json' \
  -d '{
    "query": "What is LTE?",
    "texts": [
      "LTE is a 4G cellular standard from 3GPP.",
      "Espresso is a concentrated coffee brewing method.",
      "5G NR succeeded LTE as the dominant mobile standard."
    ]
  }' | python3 -m json.tool
# Returns scored, sorted indices into texts[]; LTE-related entries score highest.
```

**Batching candidates in one call.** A single `/rerank` request takes one
`query` + an array of candidate `texts` — that IS the batch. Up to 32
candidates per request works out of the box (TEI's
`--max-client-batch-size` default). For the typical RAG flow
(retrieve top-25 by embedding, rerank → take top-10) just pass all 25
candidates in one call. Internal batching, single tokenization of the
query, sorted response. Defaults for bge-reranker-large:

| Param | Default | What it gates | When to change |
|---|---|---|---|
| `--max-client-batch-size` | 32 | Hard cap on `texts[]` length per request | If you need >32 candidates per call — bump in the tei-reranker command |
| `--max-batch-tokens` | 16384 | Token budget for one internal forward-pass batch | Rarely; only if many long candidates make a single request OOM |
| Per-pair max length | 512 tokens | Model architecture limit (bge-reranker-large = XLM-RoBERTa base) | Pass `truncate: true` in the body for chunks longer than ~450 tokens, or pre-chunk smaller |

On the GPU build (local/tei:gb10) the Candle backend processes all candidates
in a single forward pass — the 8-pair `max_batch_requests` cap is an ORT/CPU
constraint that doesn't apply here. Expected latencies on GB10 with default
settings (bge-reranker-large) — **estimates pending measurement on first
deploy**:

| Candidates per call | Latency (estimated) |
|---|---|
| 8 | ~10-30 ms |
| 25 | ~20-60 ms |
| 32 | ~25-80 ms |
| 50+ | split into parallel calls (avoids `--max-client-batch-size` cap) |

Run a few real calls after the GPU cutover and update these numbers — the
range above is extrapolated from embedder latencies and may be off by ~2× in
either direction depending on sequence length distribution.

**Multi-query rerank.** `/rerank` is one query, N texts. For M queries
each with their own candidates, fire M separate requests in parallel
(`asyncio.gather`) — TEI's `--max-batch-requests` is unlimited so
concurrent calls share GPU/CPU time cleanly.

**Swap the reranker model**: download it (`./hf-curl-download.sh <user/repo>`),
set `TEI_RERANKER_MODEL=<bare-name>` in `.env`, then `make restart svc=tei-reranker`
(~30s reload).

## Observability (memory monitoring)

Full plain-language guide in **[OBSERVABILITY.md](OBSERVABILITY.md)**.
Cheat sheet for the operational view:

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

One lever — `VLLM_GPU_UTIL` (fraction of the full 128 GB pool). The TEI
services take a fixed ~8 GB off the top; Ollama uses whatever vLLM + TEI
leave. See README for the conversion table.
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
