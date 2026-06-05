# apex-spark-01 service stack

Docker Compose stack for the DGX Spark (GB10 / aarch64 / CUDA 13): backend data
services, GPU inference (vLLM + Ollama + TEI), and a Caddy gateway — all behind
one `make` interface.

## First-time deploy
Follow **[SETUP.md](SETUP.md)** — the full ordered procedure (preflight, NGC
login, storage provisioning, decisions, launch). TL;DR once the box is
provisioned and you're in `/data/srv`:
```bash
cp .env.example .env          # fill in, then chmod 600 (sops optional — see SETUP.md A8)
make init && make up && make models
make health
```
Service data is bind-mounted onto `/data/srv/data/*` (durable, backed up) and
models onto `/data/models/*` (disposable) — **not** Docker named volumes. Disk
layout in [STORAGE.md](STORAGE.md); day-to-day ops in [RUNBOOK.md](RUNBOOK.md).

## Downloading images and models

In normal networks `docker pull` and `huggingface-hub` Just Work, and you can
skip this section. Behind aggressive corp proxies — HTTP/2 stream resets,
multi-connection downloads stalling mid-transfer, manifest fetches returning
EOF — the bundle ships proxy-tolerant fallbacks for both. All three operations
below are `make` one-liners; the scripts behind them handle retries, resume,
and verification automatically.

### Docker images — `make pull-stack`

`docker pull` opens many parallel streams; corp proxies often choke on those.
`skopeo` uses single-connection HTTPS (the kind proxies tolerate) and writes
each image to a local tarball, which `docker load` then registers. Same end
state as `docker pull`, just a different transport.

```bash
# Pull every image referenced in compose*.yml. Idempotent: images already
# present locally are skipped. Retries each pull up to 3× with backoff.
make pull-stack

# Just one image:
make pull-stack images="nvcr.io/nvidia/vllm:25.11-py3"
```

**Auth**:
- `nvcr.io/*` (vLLM, dcgm-exporter): `export NGC_API_KEY=...` in your shell
  first. Get the key at https://ngc.nvidia.com/setup/api-key.
- `gcr.io`, `ghcr.io`, Docker Hub: public images — no auth needed.

**Diagnostics**: pulls log to `~/skopeo-pull-stack.log`. Tarballs land in
`/tmp/` and are deleted after `docker load` (set `KEEP_TARS=1` to keep them
for sneakernet copies). For registries that even skopeo can't reach, build
or pull off-box and `docker save` → sneakernet → `docker load` on the
spark — see SETUP.md B2-build for the TEI example.

### HuggingFace models — `make download-models` and `hf-curl-download.sh`

The `hf` / `huggingface-hub` Python clients open many concurrent streams per
file and resume sloppily; corp proxies often establish the connections but
deliver zero bytes. `hf-curl-download.sh` uses one curl per file (resumable),
and — critically — **verifies each downloaded file's size against the HF API
after the transfer**, catching silent mid-stream truncations that leave curl
exiting 0 with a short file (the symptom that previously caused vLLM to fail
with `SafetensorError: incomplete metadata`).

**Bulk pre-download** (uses `VLLM_MODEL` + `TEI_MODEL` from `.env`):

```bash
make download-models
make download-models models="Qwen/Qwen3-32B-AWQ BAAI/bge-m3"
./download-models.sh -f models-list.txt           # one ID per line; # = comment
```

**One model at a time**:

```bash
./hf-curl-download.sh Qwen/Qwen3-32B-AWQ
./hf-curl-download.sh BAAI/bge-m3 /data/models/local/bge-m3
```

Default destination: `/data/models/local/<repo-basename>` — a flat directory
that vLLM/TEI can read directly. Re-running is safe — already-complete files
are size-verified and skipped.

**Auth**: uses `$HF_TOKEN` from your shell or `.env`, falls back to
`~/.cache/huggingface/token`. Gated models need a token with access.

**Logs**: `~/hf-download.log` (bulk) or stdout (single). If a model gets
stuck, run `./diagnose-hf.sh` to test which transport works through your
proxy — that's the script that told us curl works where the HF CLI didn't.

### vLLM model setup

vLLM loads ONE model at boot, named by `VLLM_MODEL` in `.env`. After
downloading, point vLLM at the model and restart that one service.

**Three valid forms** for `VLLM_MODEL` (auto-detected by a resolver in
`compose.inference.yml`):

| Form | Example | Resolves to | Use when |
|---|---|---|---|
| **Bare name** *(preferred)* | `Qwen3-32B-AWQ` | `/data/local/Qwen3-32B-AWQ` | Downloaded via `hf-curl-download.sh` — the typical case |
| Absolute path | `/data/local/Qwen3-32B-AWQ` | (used as-is) | Model lives outside `/data/local/` or legacy `.env` files |
| HF repo ID | `Qwen/Qwen3-32B-AWQ` | HF cache lookup under `/data/hf-cache` | Downloaded via standard HF CLI (cache layout) |

The resolver also sets vLLM's `--served-model-name` to a clean short name
(basename for paths, full repo ID for HF lookups), so OpenAI-compatible API
clients use the short form regardless of which `.env` value you picked:

```bash
# Same short model name works for all three VLLM_MODEL forms above
curl http://apex-spark-01.local/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{"model": "Qwen3-32B-AWQ", "messages": [...]}'
```

**Switching models**:
```bash
./hf-curl-download.sh Qwen/Qwen3-14B-AWQ             # 1. download
sudo $EDITOR /data/srv/.env                          # 2. set VLLM_MODEL=Qwen3-14B-AWQ
make restart svc=vllm                                # 3. restart vLLM only (~2-5 min reload)
```
Ollama is unaffected by this — it keeps whatever model it had loaded.

**Reasoning models** (Qwen3-*, DeepSeek-R1): also set
`VLLM_REASONING_PARSER=qwen3` (or `deepseek_r1`) so the `<think>` trace gets
routed into `message.reasoning_content` rather than appearing in
`message.content`. See RUNBOOK.md "Model management".

**Verifying what vLLM is serving** (after restart finishes):
```bash
docker compose -f compose.inference.yml exec vllm curl -s localhost:8000/v1/models
```

## GPU memory budget (128 GB unified)

| Consumer | Target | Enforced by |
|---|---|---|
| OS + backend services | ~16 GB reserved | left unallocated |
| **vLLM** — 75% of inference pool | ~84 GB | `VLLM_GPU_UTIL=0.65` (fraction of the **full** 128 GB) |
| **Ollama** — 25% of inference pool | ~28 GB | `OLLAMA_MAX_LOADED_MODELS=1` + model choice ≤ ~26 GB |

Two facts this depends on:
- **vLLM pre-allocates at boot**, so `make up` starts it *first* and waits for
  `/health` before launching Ollama. Don't reorder this.
- **Ollama has no hard memory cap** — its slice is enforced by loading one model
  at a time. While vLLM is up, a 70B will NOT fit in Ollama's 28 GB; stick to
  ≤32B-Q4 / ≤27B-Q8 there. Run big models *through vLLM* instead.

### Changing the split

There is **one lever: `VLLM_GPU_UTIL`** (fraction of the full 128 GB pool that
vLLM pre-allocates). Ollama has no reservation — it simply uses whatever vLLM
leaves free, so lowering vLLM's value automatically gives Ollama more, and vice
versa. The OS + backend services need ~16 GB out of "Ollama's" remainder.

| `VLLM_GPU_UTIL` | vLLM gets | Left for Ollama (after ~16 GB OS/svc) | Ollama can run |
|---|---|---|---|
| 0.35 | ~45 GB | ~67 GB | up to a 70B-Q4 |
| 0.50 | ~64 GB | ~48 GB | a 70B-Q4 (tight) |
| 0.65 *(default)* | ~84 GB | ~28 GB | ≤32B-Q4 / ≤27B-Q8 |
| 0.75 | ~96 GB | ~16 GB | small models only (≤14B) |
| 0.85 | ~109 GB | ~3 GB | effectively vLLM-only |

**Permanent change** — edit `.env`, then restart vLLM (the only service that
needs to re-allocate):
```bash
make rebalance util=0.50     # writes VLLM_GPU_UTIL to .env + restarts vLLM
# equivalently: edit .env, then  make restart svc=vllm
```
Restarting vLLM drops its loaded model briefly (~minutes to reload); Ollama is
unaffected and picks up the freed memory on its next model load.

**Temporary: give Ollama the whole box** (e.g. to run a 70B in Ollama once)
without editing the split — just stop vLLM; restart it when done:
```bash
make vllm-stop     # frees vLLM's entire slice for Ollama
# ... run your large Ollama job ...
make vllm-start    # reclaims the configured VLLM_GPU_UTIL slice
```

> Order still matters: whenever both are wanted, vLLM must be running (and have
> grabbed its slice) **before** Ollama loads a model, or Ollama may take memory
> vLLM then can't reclaim without a restart.

## Routes (via Caddy, https://$SITE_HOST)
| Path | Backend | Use |
|---|---|---|
| `/v1/*` | vLLM :8000 | OpenAI-compatible chat/completions. **Also served on plain HTTP** (`http://$SITE_HOST/v1/*`) so cert-averse clients (SIRA, generic scripts) can skip TLS. Other paths on HTTP redirect to HTTPS. For Qwen3 / DeepSeek-R1, the reasoning parser is enabled via `VLLM_REASONING_PARSER` in `.env` — `<think>` blocks are routed into `choices[].message.reasoning_content` so `message.content` carries only the clean answer. |
| `/ollama/*` | Ollama :11434 | Ollama API |
| `/embed/*` | TEI :80 | embeddings for RAG |
| `/rerank/*` | tei-reranker :80 | cross-encoder reranking for RAG (Cohere-compatible `/rerank` endpoint). Same TEI image, different model — CPU-only, no GPU stake. Default model `bge-reranker-large` (~568M, xlm-roberta). Reranker selection requires both ONNX weights on HF and a `model_type` field in config.json — see `.env.example` for the cautionary list (`bge-reranker-v2-m3` lacks ONNX; `jina-reranker-v2-base-multilingual` lacks `model_type`). |
| `/` (root + anything unmatched) | open-webui :8080 | browser chat UI for vLLM (first signup → admin). `/chat` redirects to `/` for backward-compat. |
| `/apex/*` | *(not wired)* | reserved for your apps; uncomment in `Caddyfile` after adding to `compose.apps.yml` |
| `/grafana/*` | Grafana :3000 | dashboards (browser auth) |

## Reaching the stack from other machines

**Always use the hostname (`$SITE_HOST`) in URLs, never the raw IP.** Caddy's
TLS stack (Go crypto/tls) has a long-standing issue with IP-literal SNI —
`openssl s_client` works, but `curl`/`wget`/Python clients fail with
`tlsv1 alert internal error` when the URL is `https://<ip>/`. Hostname SNI
works for every client.

To make this work on every machine that needs access:

- **DNS** (cleanest): get an A record `apex-spark-01.<corp-domain>` →
  spark's IP in corp DNS.
- **mDNS** (zero-config on LAN): `sudo apt install avahi-daemon` on the
  spark; Linux/Mac machines auto-resolve `apex-spark-01.local`.
- **`/etc/hosts`** (simplest, per-machine): add one line on every client.
  ```
  <spark-ip>  apex-spark-01.local
  ```
  Windows: `C:\Windows\System32\drivers\etc\hosts` (edit as Admin).

`.env` should always have `SITE_HOST=apex-spark-01.local` (or your real
hostname) — never the IP. The `SITE_ADDRESSES` extension point exists for
listing multiple hostnames if you want, but **don't put an IP in there**;
the cert gets issued but clients can't use it.

## Securing the gateway
The gateway is **currently unauthenticated** — `Caddyfile` proxies directly to
each backend. This is only acceptable if the box lives on a trusted VPN /
restricted network where every reachable user is allowed to use every service.

Still do: keep the box VPN-only and swap `tls internal` for corp PKI certs.

If you later need auth, three lightweight options:
- **Basic auth (htpasswd)** per route via Caddy's `basicauth` directive.
- **Static API key** for `/v1/*`, `/embed/*`, `/ollama/*` — header matcher:
  ```
  @noauth not header Authorization "Bearer {$API_KEY}"
  respond @noauth 401
  ```
- **Full IdP integration** — restore oauth2-proxy + `forward_auth` (see git
  history of `compose.gateway.yml` + `Caddyfile`).

## Observability
Prometheus + Grafana + exporters come up with `make up`. Grafana is at
`https://$SITE_HOST/grafana` (login `admin` / `GRAFANA_PASSWORD`). For the
plain-language walkthrough — how Prometheus/Grafana/exporters fit together,
panel-by-panel guide to the **Service Memory** dashboard, useful PromQL
queries, and the `make watch-vllm` / `make watch-vllm-load` command-line
monitors — see **[OBSERVABILITY.md](OBSERVABILITY.md)**.

## Adding a service
1. Confirm arm64: `docker manifest inspect <image> | grep arm64`
2. Add it to `compose.apps.yml` on the `apex` network, no published ports.
3. Add a route in `Caddyfile`, then `make deploy`.

## Day-to-day operations
See [RUNBOOK.md](RUNBOOK.md) — health checks, model management, memory
rebalancing, storage/quota ops, user management, backups, and a
symptom→fix troubleshooting table.

## Files
- `docker-compose.yml` — postgres, redis, qdrant, minio
- `compose.inference.yml` — vllm, ollama, tei (GPU)
- `compose.gateway.yml` + `Caddyfile` — reverse proxy / TLS
- `compose.apps.yml` — your apps (example included)
- `compose.observability.yml` + `observability/` — Prometheus, Grafana, exporters
- `Makefile` — the interface
- `.env.example` — copy to `.env`, fill, encrypt
- `setup-storage.sh` — storage bring-up (see STORAGE.md)
- `install-system.sh` (`make install-system`) — docker log rotation + journald cap
- `system/` — `daemon.json`, `journald-apex.conf` (installed by the above)
- `health.sh` (`make health`) — daily health checks / cron probe
- `vllm-watch.sh` (`make watch-vllm`) — live vLLM memory + KV cache + queue monitor (full view)
- `vllm-watch-load.sh` (`make watch-vllm-load`) — saturation-focused subset for load tests
- `backup.sh` (`make backup`) — backups (see RUNBOOK.md)
- `download-models.sh` (`make download-models`) — bulk HF model pre-download
- `skopeo-pull-stack.sh` (`make pull-stack`) — pull all stack images via skopeo (proxy fallback when `docker pull` fails)
- `load-tei-on-spark.sh` — load the TEI image tarball built off-box (see SETUP.md B2-build)
- `diagnose-hf.sh` — HF download stall diagnostics
- `SETUP.md` — first-time deployment procedure
- `STORAGE.md` / `RUNBOOK.md` / `OBSERVABILITY.md` — disk layout / day-to-day operations / dashboards + live monitoring
