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
| `/v1/*` | vLLM :8000 | OpenAI-compatible chat/completions |
| `/ollama/*` | Ollama :11434 | Ollama API |
| `/embed/*` | TEI :80 | embeddings for RAG |
| `/chat/*` | open-webui :8080 | browser chat UI for vLLM (first signup → admin) |
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
Prometheus + Grafana + exporters (cAdvisor, node-exporter, dcgm-exporter) come up
with `make up`. Grafana is at `https://$SITE_HOST/grafana` (login `admin` /
`GRAFANA_PASSWORD`), with a provisioned **Service Memory** dashboard: per-container
memory, memory vs. limit, host memory (the 128 GB unified pool), and GPU
framebuffer. Set `GRAFANA_PASSWORD` in `.env`. Own footprint ~1.5 GB; TSDB capped
at 15-day retention. This is how you'll measure the real per-service RAM before
finalizing the memory split.

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
- `backup.sh` (`make backup`) — backups (see RUNBOOK.md)
- `download-models.sh` (`make download-models`) — bulk HF model pre-download
- `skopeo-pull-stack.sh` (`make pull-stack`) — pull all stack images via skopeo (proxy fallback when `docker pull` fails)
- `load-tei-on-spark.sh` — load the TEI image tarball built off-box (see SETUP.md B2-build)
- `diagnose-hf.sh` — HF download stall diagnostics
- `SETUP.md` — first-time deployment procedure
- `STORAGE.md` / `RUNBOOK.md` — disk layout / operations
