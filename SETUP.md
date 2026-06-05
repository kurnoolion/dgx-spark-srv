# SETUP — first-time deployment to the DGX Spark

The procedure splits cleanly into **Part A (no docker network needed)** and
**Part B (after IT clears the docker proxy exception)**. Everything in Part A
can be done while waiting on IT; Part B brings the inference + service stack
online. For disk layout see [STORAGE.md](STORAGE.md); for recurring ops see
[RUNBOOK.md](RUNBOOK.md). **Decision points and likely blockers are bold.**

---

## Part A — Pre-docker setup *(no IT exception needed)*

All of these work with normal host network (your corp proxy is enough). They
**don't pull any docker images** — those are all in Part B.

### A1. Preflight — get the bundle on the box, confirm hardware
1. Copy the bundle to a **temporary** location — *not* `/data/srv` (it doesn't exist yet):
   ```bash
   rsync -av ~/work/dgx-spark-srv/  user@spark:~/dgx-spark-srv/
   cd ~/dgx-spark-srv
   ```
2. Confirm GPU is visible (skip any `docker run` smoke tests — those require Part B):
   ```bash
   nvidia-smi                       # GB10 visible, CUDA 13
   ```
3. **Get the NGC API key now** — sign in at https://ngc.nvidia.com → Setup → Generate API Key.
   Save it somewhere safe; you'll need it at B2. **NGC enablement on a corp account often takes longer than expected**, so start this early.
4. Capture disk layout and confirm LVM headroom:
   ```bash
   lsblk -f ; sudo vgs ; sudo lvs
   ```
   `setup-storage.sh` needs free VG space. If root fills the disk, stop here — reinstall with a smaller root or add a disk first.

### A2. Decisions before any data lands
- **Encryption** — SED-lock (BIOS step, anytime) vs LUKS on `/data` (must be applied **before** `setup-storage.sh --apply`; the script doesn't add LUKS itself). Required if MNO/compliance data will live here.
- **Compliance data scope** — informs logging, network controls, backup retention.

### A3. Provision storage
```bash
sudo ./setup-storage.sh                         # DRY RUN — read the plan
sudo ./setup-storage.sh --apply --move-docker   # apply
```
Verify per STORAGE.md's checklist (`vgs`, `lvs`, `df -hT`, `findmnt /home`, project quotas).

### A4. Install (or re-install) Docker + NVIDIA Container Toolkit

DGX OS ships Docker by default, but this section is the clean reinstall path —
use it if Docker is broken, was never installed, or you just want a known-good
state with proxy + NVIDIA runtime correctly wired. **All commands assume the
corp proxy env vars are set in your shell** (`HTTP_PROXY` / `HTTPS_PROXY` / `NO_PROXY`).

#### A4.1 Remove the old install (skip if installing fresh)
```bash
sudo systemctl stop docker docker.socket 2>/dev/null || true
sudo apt-get remove -y docker.io docker-doc docker-compose docker-compose-v2 \
                       podman-docker containerd runc 2>/dev/null || true
sudo apt-get remove -y docker-ce docker-ce-cli containerd.io \
                       docker-buildx-plugin docker-compose-plugin 2>/dev/null || true
sudo apt-get autoremove -y --purge
# NOTE: keeps /var/lib/docker (your new docker LV) — only wipe if you're sure:
# sudo rm -rf /var/lib/docker /var/lib/containerd /etc/docker
sudo rm -rf /etc/systemd/system/docker.service.d
```

#### A4.2 Configure apt proxy (if not already)
```bash
sudo tee /etc/apt/apt.conf.d/95proxy <<EOF
Acquire::http::Proxy "${HTTP_PROXY}";
Acquire::https::Proxy "${HTTPS_PROXY}";
EOF
```

#### A4.3 Install Docker CE from Docker's official repo
```bash
sudo apt-get update
sudo apt-get install -y ca-certificates curl gnupg
sudo install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
  | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
sudo chmod a+r /etc/apt/keyrings/docker.gpg
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo $VERSION_CODENAME) stable" \
  | sudo tee /etc/apt/sources.list.d/docker.list
sudo apt-get update
sudo apt-get install -y docker-ce docker-ce-cli containerd.io \
                        docker-buildx-plugin docker-compose-plugin
```

#### A4.4 Install + configure NVIDIA Container Toolkit
```bash
curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey \
  | sudo gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg
curl -s -L https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list \
  | sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' \
  | sudo tee /etc/apt/sources.list.d/nvidia-container-toolkit.list
sudo apt-get update
sudo apt-get install -y nvidia-container-toolkit
sudo nvidia-ctk runtime configure --runtime=docker      # writes nvidia runtime into /etc/docker/daemon.json
```

#### A4.5 Wire the corp proxy into the docker daemon
The docker daemon runs under systemd and does **not** inherit your shell's proxy.
This drop-in is what makes `docker pull` reach NGC / Docker Hub:
```bash
sudo mkdir -p /etc/systemd/system/docker.service.d
sudo tee /etc/systemd/system/docker.service.d/proxy.conf <<EOF
[Service]
Environment="HTTP_PROXY=${HTTP_PROXY}"
Environment="HTTPS_PROXY=${HTTPS_PROXY}"
Environment="NO_PROXY=${NO_PROXY:-localhost,127.0.0.1,::1}"
EOF
sudo systemctl daemon-reload
sudo systemctl restart docker
```

#### A4.6 Add yourself to the `docker` group
Do this BEFORE the verify step — `docker info` needs socket access, which is
group-gated. Without `docker` group membership you'll get
*"permission denied while trying to connect to the Docker daemon socket"*.
```bash
sudo usermod -aG docker $USER
newgrp docker           # apply to current shell without logout
docker ps               # smoke: should work without sudo (empty list is fine)
```

#### A4.7 Verify (smoke tests — defer image pulls until IT clears NGC)
```bash
docker info | grep -iE 'server version|runtimes'        # expect nvidia runtime listed
systemctl show docker --property=Environment | head     # proxy vars populated
docker run --rm hello-world                              # if proxy/NGC cleared
# only if NGC is reachable:
# docker run --rm --gpus all nvcr.io/nvidia/cuda:12.6.0-base-ubuntu22.04 nvidia-smi
```

> **Important — order with A5:** `make install-system` (next step) merges log
> rotation into `daemon.json`. That merge **must** preserve the NVIDIA runtime
> config that `nvidia-ctk` just wrote. The installer uses `jq` to merge safely;
> if you ever lose the NVIDIA runtime config, re-run `sudo nvidia-ctk runtime
> configure --runtime=docker && sudo systemctl restart docker`.

### A5. Place the bundle + install host hygiene
```bash
sudo rsync -a ~/dgx-spark-srv/ /data/srv/ && cd /data/srv
sudo make install-system            # daemon.json (jq-MERGED, preserves nvidia runtime) + journald cap
sudo systemctl restart docker
```
Verify nvidia runtime survived: `docker info | grep -i runtime`.

### A6. Configure `.env`
```bash
cp .env.example .env
${EDITOR:-vi} .env
```
Fill in (the bundle is **unauthenticated at the gateway** — see README's Securing section):
- Secrets: `PG_PW`, `MINIO_*`, `GRAFANA_PASSWORD`, `HF_TOKEN`
- `SITE_HOST` (hostname Caddy answers on)
- `BACKUP_DIR` (default fine)

Leave blank for now: `RESTIC_REPO` (no DR target yet), `OIDC_*` / `OAUTH2_*` (auth removed).

### A7. Create the bind-mount dirs
```bash
make init
```
This also sets `ml-users` as group on the shared `/data/models/{hf-cache,ollama,shared}` dirs so any user in the group can populate them without sudo.

### A8. Lock down `.env` permissions (sops is *optional*)

For this box's threat model — single-tenant, VPN-only, no off-box `.env`
backups — **`chmod 600` plus SED firmware lock is enough.** Adding sops on top
gives marginal security (anyone with root can read `~/.age-key.txt` too) at real
operational cost (compose can't read encrypted `.env` without a decrypt wrapper).

```bash
sudo chmod 600 /data/srv/.env
sudo ls -la /data/srv/.env          # expect: -rw------- root root
```
Enable **SED firmware lock in BIOS** now if you haven't — that's the actual
data-at-rest defense (Open decision #1).

#### Only do this if you'll back `.env` off-box (git, shared store, etc.)

Use **binary mode** to sidestep sops's dotenv/JSON format-detection traps that
chew up an hour the first time you hit them:

```bash
# install sops + age (one-time)
sudo apt install age
SOPS_VER=v3.9.1         # verify latest at https://github.com/getsops/sops/releases
curl -L -o /tmp/sops "https://github.com/getsops/sops/releases/download/${SOPS_VER}/sops-${SOPS_VER}.linux.arm64"
sudo install -m 755 /tmp/sops /usr/local/bin/sops && rm /tmp/sops

# generate age key (BACK THIS UP SOMEWHERE SAFE — losing it = losing .env.enc)
age-keygen -o ~/.age-key.txt && chmod 600 ~/.age-key.txt
PUB=$(grep '^# public key:' ~/.age-key.txt | awk '{print $4}')

# encrypt as opaque binary — robust, no format gotchas
sudo SOPS_AGE_KEY_FILE=$HOME/.age-key.txt sops \
    --input-type binary --output-type binary \
    --age "$PUB" --encrypt /data/srv/.env \
  | sudo tee /data/srv/.env.enc > /dev/null

# verify decrypt BEFORE relying on it
sudo SOPS_AGE_KEY_FILE=$HOME/.age-key.txt sops \
    --input-type binary --decrypt /data/srv/.env.enc | head -5
```
Plaintext `.env` stays in place for compose to read; `.env.enc` is what you'd
commit/back-up. Keep `~/.age-key.txt` offline.

### A9. Install dev tooling *(per user — small, in `~/.local/`)*
Each user who needs CLI tools runs:
```bash
curl -LsSf https://astral.sh/uv/install.sh | sh && source ~/.bashrc
uv tool install 'huggingface_hub[cli,hf_transfer]'
# binary is `hf` (new CLI in huggingface_hub ≥ 0.24); `huggingface-cli` is the
# legacy alias. download-models.sh handles either.
which hf || which huggingface-cli
```
System-wide `HF_HOME` so all users hit the shared cache:
```bash
echo 'export HF_HOME=/data/models/hf-cache' | sudo tee /etc/profile.d/hf.sh
echo 'export HF_HUB_ENABLE_HF_TRANSFER=1'   | sudo tee -a /etc/profile.d/hf.sh
```
Add yourself to `ml-users` and log out/in:
```bash
sudo usermod -aG ml-users $USER
```

### A10. Pre-download HF models — biggest pre-docker time-saver
Use the bundled `download-models.sh` (retry logic, logging, defaults from `.env`):
```bash
hf auth login                          # paste HF_TOKEN (one-time)
                                       # (legacy: `huggingface-cli login`)
# uses VLLM_MODEL + TEI_MODEL from .env if readable; otherwise pass models below.
# .env is mode 600 root:root, so as a normal user pass models explicitly:
make download-models models='Qwen/Qwen2.5-32B-Instruct BAAI/bge-m3'

# or from a file (one ID per line, # for comments) — recommended for >2-3 models:
./download-models.sh -f my-models.txt
```
Safe to fire-and-forget overnight — logs to `~/hf-download.log`, retries each
model 3 times with backoff, skips fully-cached files on re-run. When `make up`
runs in Part B, vLLM and TEI find these on disk — zero re-download.

#### Fallback: `hf-curl-download.sh` (when `hf download` stalls through the proxy)
Some corp proxies open TCP to HF but **don't transfer the response body** for
the Python downloader, even though `curl` works fine. Symptom: `du -sh
/data/models/hf-cache` flat; `.incomplete` blob files at 0 bytes;
`diagnose-hf.sh` shows API probes succeeding. Use the curl-based downloader:
```bash
./hf-curl-download.sh Qwen/Qwen3-32B-AWQ           # → /data/models/local/Qwen3-32B-AWQ/
./hf-curl-download.sh BAAI/bge-m3                  # embedder
./hf-curl-download.sh BAAI/bge-reranker-large      # reranker — see note
```
This bypasses `hf` entirely, writes a flat directory, and resumes interrupted
downloads. Set the bare model names in `.env` (the compose resolver expands
them to `/data/local/<name>` inside the container):
```
VLLM_MODEL=Qwen3-32B-AWQ
TEI_MODEL=bge-m3
TEI_RERANKER_MODEL=bge-reranker-large
```
**Reranker note**: TEI's CPU/arm64 build is strict about reranker models —
they need **(a) an ONNX export on HF** (`onnx/model.onnx`; required by the
ORT backend) AND **(b) a `model_type` field in `config.json`** (TEI's
parser doesn't follow `auto_map`). Two near-misses we hit:
- `BAAI/bge-reranker-v2-m3` ships only PyTorch safetensors — no ONNX
  export, fails (a) with "File at '.../onnx/model.onnx' does not exist".
- `jinaai/jina-reranker-v2-base-multilingual` ships ONNX but uses
  `auto_map` + custom `XLMRobertaFlashConfig`, fails (b) with "missing
  field 'model_type'".
`bge-reranker-large` clears both; `.env.example` lists other verified
drop-ins (`bge-reranker-base`, `mixedbread-ai/mxbai-rerank-{base,large}-v1`).

### A11. Install restic (for backups)
```bash
sudo apt install restic
```
`make backup` will work end-to-end once `RESTIC_REPO` is set (B6 below).

### A12. Schedule crons *(inert until services come up — auto-engages then)*
```cron
15 2  * * *    cd /data/srv && ./backup.sh        >> /var/log/apex-backup.log 2>&1
30 3  * * 0    cd /data/srv && make prune         >> /var/log/apex-prune.log  2>&1
*/15 *  * * *  cd /data/srv && make health        >/dev/null 2>&1 || echo "apex health FAILED $(date)" >> /var/log/apex-health.log
```
The health check will FAIL noisily until Part B completes — that's fine; suppress alerting on it until then.

### A13. PARK — wait for IT to clear the docker proxy exception
Verify nothing else is missing in [Open decisions](#open-decisions) below.

---

## Part B — Post-docker bring-up *(after IT clears proxy)*

### B1. Verify docker pulls actually work
```bash
docker pull hello-world                                           # tiny smoke test
docker pull nvcr.io/nvidia/cuda:12.6.0-base-ubuntu22.04            # NGC reachable?
```
If the small image works but NGC fails with TLS errors, install the corp CA:
```bash
sudo cp <corp-ca>.crt /usr/local/share/ca-certificates/
sudo update-ca-certificates
sudo systemctl restart docker
```

> **If `docker pull` fails with `EOF` or hangs even after IT exception**
> (proxy doesn't get along with docker daemon's HTTP/2 / Go client pattern),
> use **skopeo** as the proxy-friendly fallback — skip B2 (skopeo handles
> NGC auth via `NGC_API_KEY` env var) and jump to B2-alt below.

### B2. Log in to NGC (using the key from A1.3) — only needed if `docker pull` works
```bash
docker login nvcr.io
```

### B2-alt. Skopeo fallback — proven path when docker daemon can't pull
Skopeo uses libcurl semantics, which most corp proxies accept where docker
daemon doesn't. `make pull-stack` auto-extracts the image list from the compose
files; idempotent (skips already-loaded); retries 3× per image.

#### Install + smoke test (1 small image first)
```bash
sudo apt install -y skopeo
cd /data/srv
make pull-stack images='caddy:2'           # ~50 MB; proves the pipeline works
docker images | grep caddy                 # should show: caddy 2 <id> ...
```

#### Then pull in two batches — public registries first, NGC second

**Public-registry images (no auth — 11 of 13):**
```bash
make pull-stack images='postgres:16 redis:7 qdrant/qdrant:latest \
  minio/minio:latest ollama/ollama:latest grafana/grafana:latest \
  prom/prometheus:latest prom/node-exporter:latest \
  caddy:2 \
  gcr.io/cadvisor/cadvisor:v0.49.1 \
  ghcr.io/open-webui/open-webui:main'
```

> **TEI** is included in the stack but **must be built from source** —
> HuggingFace doesn't publish an arm64 prebuilt (verified `:latest` and
> `:cpu-latest` are both `linux/amd64` only on aarch64 inspection). Build
> instructions in **B2-build** below. The other 11 images you pull here;
> TEI image gets built locally.

**NGC images (need API key from A1.3):**
```bash
export NGC_API_KEY=<your-ngc-api-key>
make pull-stack images='nvcr.io/nvidia/vllm:25.11-py3 \
  nvcr.io/nvidia/k8s/dcgm-exporter:3.3.9-3.6.1-ubuntu22.04'
```

> **vLLM image is ~20 GB** at your proxy throughput it may take **hours**.
> Run it under `tmux` or `nohup` so a dropped SSH doesn't kill it:
> ```
> nohup make pull-stack images='nvcr.io/nvidia/vllm:25.11-py3' &> ~/vllm-pull.log &
> disown
> tail -f ~/vllm-pull.log
> ```

#### Verify the 12 pulled images landed
```bash
docker images | sort
# expect 13 entries (the stack minus TEI), each with proper REPOSITORY:TAG
# (TEI will be built locally in B2-build below → 14 total after that)
```

### B2-build. Build TEI from source (no arm64 prebuilt exists)

TEI is in `compose.inference.yml` but its image is `local/tei:cpu-arm64` — you
build it on the spark. Default below is the **CPU/arm64 build** for v1
(~15 min, ~50-150ms/embedding, no GPU mem cost). GPU build is an upgrade path.

#### Pre-pull the build base image (docker build can't `docker pull` either)
Inspect the FROM line so you know which base to pre-pull via skopeo:
```bash
cd ~ && git clone https://github.com/huggingface/text-embeddings-inference
cd text-embeddings-inference
grep -m1 ^FROM Dockerfile-arm64
# typical: FROM ubuntu:22.04 AS base   (or similar)
```
Pre-pull whatever it says (substitute below if different):
```bash
cd /data/srv
make pull-stack images='ubuntu:22.04'    # the FROM base for Dockerfile-arm64
```

#### Build the CPU/arm64 image (v1 default)
```bash
cd ~/text-embeddings-inference
docker build -f Dockerfile-arm64 --platform=linux/arm64 \
  --build-arg HTTP_PROXY=$HTTP_PROXY \
  --build-arg HTTPS_PROXY=$HTTPS_PROXY \
  --build-arg NO_PROXY=localhost,127.0.0.1,::1 \
  -t local/tei:cpu-arm64 .
docker images | grep tei                  # expect: local/tei  cpu-arm64  ...
```
Build is mostly Rust compilation (~15-20 min on the spark). Watch out for
`apt-get` or `cargo` failing on TLS errors — if so, the Dockerfile may need
the proxy ARG declared explicitly. Easiest patch:
```bash
# add at the top of Dockerfile-arm64 (just under FROM):
ARG HTTP_PROXY
ARG HTTPS_PROXY
ARG NO_PROXY
ENV HTTP_PROXY=$HTTP_PROXY HTTPS_PROXY=$HTTPS_PROXY NO_PROXY=$NO_PROXY
```
…then re-run the docker build.

#### (Optional, upgrade path) GPU build for sm_121
Build is longer (~30-60 min), needs the CUDA base from NGC:
```bash
make pull-stack images='nvcr.io/nvidia/cuda:12.6.0-devel-ubuntu22.04'  # adjust per Dockerfile-cuda's FROM
docker build -f Dockerfile-cuda --platform=linux/arm64 \
  --build-arg CUDA_COMPUTE_CAP=121 \
  --build-arg HTTP_PROXY=$HTTP_PROXY \
  --build-arg HTTPS_PROXY=$HTTPS_PROXY \
  -t local/tei:gb10 .
```
Then in `.env`:
```
TEI_IMAGE=local/tei:gb10
```
And re-add the GPU reservation block to `tei:` in `compose.inference.yml`
(copy the structure from the `vllm:` service). Drop `VLLM_GPU_UTIL` ~0.03 to
make ~4 GB headroom for TEI's GPU footprint, or you'll OOM.

After either build, `tei` is ready to start when `make up` runs.

#### Fallback: build off-box, sneakernet the tarball

If `docker build` on the spark keeps fighting your corp proxy (BuildKit
manifest resolution, cargo fetch, apt-get TLS — every layer has its own opinion),
build on another machine with internet (your WSL is fine — use QEMU emulation).

**On WSL:** use `~/work/build-tei-arm64.sh` (a separate script outside this
bundle — does emulation setup + buildx + clone + build + `docker save`):
```bash
sudo ~/work/build-tei-arm64.sh                    # ~30-60 min, unattended
# output: ~/work/tei-cpu-arm64.tar (~1-2 GB)
```

**Transfer + load on spark:**
```bash
# from WSL:
rsync -av ~/work/tei-cpu-arm64.tar <user>@spark-1d46:/tmp/

# on spark:
cd /data/srv
./load-tei-on-spark.sh                            # default: /tmp/tei-cpu-arm64.tar
# or restart tei service immediately:
./load-tei-on-spark.sh --restart --cleanup        # also delete tar after
```

The load script verifies the image name matches what compose expects
(`local/tei:cpu-arm64`), auto-tags if it doesn't, and optionally restarts
the tei container.

**Or via GitHub release** (if direct network to spark isn't an option — release
assets hold up to 2 GB):
```bash
# from WSL:
gh release create tei-cpu-arm64-$(date +%Y%m%d) ~/work/tei-cpu-arm64.tar \
  --repo kurnoolion/dgx-spark-srv --title 'TEI CPU arm64 build'

# on spark:
gh release download tei-cpu-arm64-<date> --repo kurnoolion/dgx-spark-srv \
  --pattern tei-cpu-arm64.tar --dir /tmp/
./load-tei-on-spark.sh --restart --cleanup
```

After all of B2-alt + B2-build, `make up` skips pulls entirely — every image is local.

### B3. Bring up the stack
```bash
cd /data/srv
make up                              # ordered: core → vLLM (waits) → ollama/tei → gateway/apps/observability
```
`make up` will try to pull any missing images, but if you ran B2-alt above
all images are local and it just runs them. First `make up` takes a few
minutes for vLLM model load even with images cached.

### B4. Pull Ollama models
```bash
make models
```

### B5. Verify
```bash
make health                          # expect PASS / WARN, possibly dcgm-exporter FAIL
```
Browse `https://$SITE_HOST/grafana` (admin / `GRAFANA_PASSWORD`) → **APEX — Service Memory** dashboard.

**If `dcgm-exporter` is the only FAIL** (Open decision #5), bump its image tag to an aarch64 one for the box's DCGM version in `compose.observability.yml`. GPU Grafana panels stay blank until then; nothing else breaks.

### B6. Wire off-box backups (when DR target exists)
1. Set `RESTIC_REPO` + `RESTIC_PASSWORD` in `.env`, re-encrypt with sops.
2. Run `make backup` once manually to initialise the repo.
3. The cron from A11 starts pushing off-box automatically.

---

## Most likely to bite, in order
1. **NGC enablement** on a corp account (A1.3) — get the ball rolling on day one.
2. **Storage preflight** (A3) — only an issue if root fills the disk; A1.4 catches it.
3. **dcgm-exporter tag** (B5) — cosmetic; degrade gracefully.

## Open decisions
Encryption · compliance-data scope · `/home` user-count sizing · dcgm-exporter
arm64 tag · `RESTIC_REPO` target.
