# OBSERVABILITY — knowing what the stack is doing

Plain-language guide to the dashboards, the metrics behind them, and the
command-line tools for live monitoring. Assumes no prior experience with
Prometheus, Grafana, or "observability" as a discipline — concepts are
introduced as they come up. Operational fixes (what to do when a panel
shows "No data") live in [RUNBOOK.md](RUNBOOK.md); this doc is the user
guide for what's already working.

## What "observability" means here

In one sentence: **can you see what the box is doing without guessing?**

There are three time scales you'll want, each with a different tool:

| Time scale | Tool | When to use |
|---|---|---|
| **Right now** (seconds) | `make watch-vllm` / `make watch-vllm-load` in a terminal | Live load testing, "is it stuck?", quick eyeballing during a deploy |
| **Recent** (last 30 min – 6 h) | Grafana dashboard | "Did memory spike during that workload?" — most common use |
| **Historical** (days / week+) | Grafana with a longer time range | Capacity planning, trend analysis, post-mortems |

You'll likely live in Grafana for routine work, and reach for the watch
scripts only when you want a faster refresh than Grafana's 30s.

## How it fits together (one diagram)

```
┌─────────────┐    ┌─────────────┐    ┌──────────────┐
│ node-exp.   │    │ cAdvisor    │    │ dcgm-export. │
│ (host CPU/  │    │ (container  │    │ (GPU util,   │     ← "exporters":
│  RAM/disk)  │    │  CPU/RAM)   │    │  temp, power)│       services that
└──────┬──────┘    └──────┬──────┘    └──────┬───────┘       publish their
       │                  │                   │              own metrics on
       │                  │                   │              an HTTP endpoint
       │   ┌──────────────┐                  │
       │   │ vLLM /metrics│                  │
       │   │ (KV cache,   │                  │
       │   │ queue depth) │                  │
       │   └──────┬───────┘                  │
       │          │                          │
       └──────────┼──────────────────────────┘
                  │
                  ▼  (every 15s, Prometheus polls each endpoint)
          ┌───────────────┐
          │  Prometheus   │              ← time-series database
          │  (stores 15d) │                of every poll result
          └───────┬───────┘
                  │
                  ▼  (Grafana reads from Prometheus)
          ┌───────────────┐
          │   Grafana     │              ← draws the dashboards
          │ /grafana/     │                you click through in
          └───────────────┘                a browser
```

**Vocabulary** (used throughout the rest of this doc):

- **Metric** — a number that means something (e.g. "vLLM has 5 requests
  running right now"). Always a number, never text.
- **Exporter** — a small service whose only job is to publish metrics on an
  HTTP endpoint. There's one per metric source.
- **Scrape** — Prometheus's verb for "fetch the current numbers from an
  exporter." Happens every 15s in our setup.
- **Time series** — the same metric measured over time. Plotted, it's a line
  on a graph.
- **PromQL** — Prometheus's query language. You can write your own queries
  in Grafana's "Explore" tab — examples later in this doc.

## What's running

All of these start automatically with `make up`:

| Service | Container | What it reports |
|---|---|---|
| Prometheus | `srv-prometheus-1` | The database that stores everything. Doesn't produce metrics itself. |
| Grafana | `srv-grafana-1` | The web UI for dashboards. Reads from Prometheus. |
| node-exporter | `srv-node-exporter-1` | Host-level metrics: CPU %, RAM used, disk free, network. |
| cAdvisor | `srv-cadvisor-1` | Per-container metrics: each Docker container's CPU and memory. |
| dcgm-exporter | `srv-dcgm-exporter-1` | NVIDIA GPU metrics: utilization %, temperature, power, memory bandwidth. |
| vLLM `/metrics` | (built into `srv-vllm-1`) | vLLM-specific: KV cache %, requests running/waiting, preemptions, prefix cache hits. |

You don't need to interact with any of these directly. They run in the
background and Prometheus collects from them every 15s.

## Accessing Grafana

1. Get on a network that can reach the spark — corp VPN, same LAN, or a
   client with `apex-spark-01.local` in its `/etc/hosts` (see README
   "Reaching the stack from other machines").
2. Open `https://apex-spark-01.local/grafana/` in a browser.
3. Login: `admin` / value of `GRAFANA_PASSWORD` in `/data/srv/.env`.
4. First login prompts you to change the admin password — do that and store
   the new one somewhere durable.
5. Top-left menu → **Dashboards** → **APEX — Service Memory**.

**Sub-paths matter:** the trailing `/` on `/grafana/` is necessary; Grafana
serves its assets relative to that path. `https://...local/grafana` (no
slash) gets redirected to `/grafana/` by Caddy, but some browsers cache
oddly on the redirect — when in doubt include the slash.

## The Service Memory dashboard — panel by panel

Six panels. They all share the same time selector at the top right of the
page — default is **Last 6 hours** with 30s auto-refresh. You can shrink it
to **Last 15 minutes** when watching a live workload, or grow it to
**Last 7 days** when looking at trends.

### Panel 1: Per-container memory (working set)

What it shows: how much memory each running container is using *right now*,
plotted over time. One line per container. The "working set" qualifier means
"memory the kernel won't reclaim under pressure" — i.e. memory the process
actually needs, not its full virtual address space.

**Reading it**:
- vLLM container's line stays low (~3-4 GiB) even though vLLM "uses" 96 GB —
  the GPU allocation lives in **unified memory** and doesn't show up as
  container RSS. Look at the host memory panel for that.
- Postgres, qdrant, open-webui will be the next-tallest lines under load.
- Sudden growth in any line over hours = potential memory leak. Worth a
  RUNBOOK check.

### Panel 2: Per-container memory as % of its limit

Shows "No data" by default and that's **intentional**. The panel only plots
containers that have a memory limit set in compose. We deliberately don't
set limits on vLLM/Ollama (they pre-allocate or manage memory themselves)
or backend services (their footprints are predictable). If you later add a
limit-controlled service, the panel auto-populates.

### Panel 3: Host = GPU memory used % (128 GB unified pool, shared)

The most important panel on the dashboard. Why "Host = GPU"?

On GB10 the GPU and CPU share **one physical pool of 128 GB**. There is no
separate GPU framebuffer. So "memory used" is one number: the fraction of
those 128 GB currently allocated by anyone — vLLM, Ollama, OS, every
container. With the default `VLLM_GPU_UTIL=0.65` (~84 GB stake), this panel
sits at ~70-75% baseline.

**Healthy**: flat-ish line around your expected baseline (depends on
`VLLM_GPU_UTIL`). Spikes during transient work are fine.

**Warning sign**: climbing slowly over days = leak somewhere (most likely
suspect: Ollama loading models without unloading old ones, but check
container memory panel too).

### Panel 4: GPU utilization — compute & memory bandwidth (DCGM, %)

Two lines, both as %.

- **Compute %** — fraction of the GPU's compute units (SMs) actively
  executing instructions. Under heavy inference this pins to 95-100%.
- **Memory bandwidth %** — fraction of GPU memory bus capacity being used to
  move data. Reflects how much weight/KV-cache movement is happening.

**Pattern recognition**:

| Compute % | Memory bandwidth % | What it means |
|---|---|---|
| ~100% sustained | Moderate (40-70%) | Compute-bound — typical for inference on a model that fits in memory. GPU is doing as much math as it can. **This is the goal under load.** |
| Lower (60-80%) | High (80-100%) | Memory-bound — weights/KV cache movement is the bottleneck. Suggests prefix caching could help (see vLLM watch metrics). |
| Bursty (idle valleys) | Bursty (matching) | GPU not being fed work continuously. Pipeline issue upstream, not vLLM. See "Pipeline starvation" in RUNBOOK. |
| Both near 0 for hours | — | Nobody's using vLLM right now. Healthy idle state. |

### Panel 5: GPU temperature (°C)

GB10 throttles around **85-87°C**. Sustained **80°C+** under load is the
canary — you have ~5°C of headroom before clock speeds drop.

**Healthy**: 25-40°C idle; 60-75°C during sustained inference.

**Warning**: >80°C sustained → check airflow / dust / fan curve.

### Panel 6: GPU power draw (W)

Watts the GPU is currently pulling.

**Reading**: idle 10-20 W; under load 50-200+ W (depending on workload
intensity). **Flatlining at the maximum** = GPU is doing all the work it
can — typical under sustained heavy inference, paired with Compute=100%.

## Useful PromQL queries (Explore tab)

In Grafana, click **Explore** (compass icon in left rail) → pick **prometheus**
datasource → paste a query → "Run query." Lets you look at things not on the
dashboard.

```promql
# Top 10 memory-hungry containers right now
topk(10, container_memory_working_set_bytes{name!=""})

# Host memory used % (the same number as panel 3)
100 * (1 - node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes)

# GPU power draw — single line per GPU
DCGM_FI_DEV_POWER_USAGE

# vLLM request queue depth — climbing means saturation
vllm:num_requests_waiting

# vLLM cache effectiveness — higher % is better; depends on prompt structure
100 * vllm:prefix_cache_hits_total / vllm:prefix_cache_queries_total

# Disk used % per mounted filesystem (catches /var/lib/docker filling up)
100 - 100 * node_filesystem_avail_bytes{fstype!~"tmpfs|squashfs"} / node_filesystem_size_bytes
```

**Tip on `topk` and similar**: by default Prometheus shows the value at one
moment. Use the time-range selector to see how the top-N evolved — Grafana
will plot a line per series.

## Live monitoring from the command line

Grafana's 30s refresh is fine for ambient watching but slow for "what's
happening *right now*" during a load test or while waiting for a model to
finish loading. The watch scripts give you 1-2 second refreshes against the
same underlying metrics, plus inline interpretation.

### `make watch-vllm` — full picture, 2s refresh

Use this when you want the whole vLLM story on one screen. Sample output
(annotated):

```
14:32:17   vLLM watch (refresh 2s · Ctrl-C to exit)

── Unified memory pool (GPU+CPU share this) ────                     ← Panel 3
             total        used        free    shared  buff/cache available
Mem:         121Gi       106Gi       1.4Gi      150Mi        14Gi      14Gi
  GPU util: 96%                                                       ← Panel 4 (compute)

── vLLM container (process-level only — NOT GPU allocation) ───      ← Panel 1
  CPU=103.21%   container-MEM=3.522GiB / 121.7GiB (2.89%)   PIDS=131
  (vLLM's 96 GB stake doesn't show here on unified memory — see 'free' above)

── vLLM internals (cache + request stats from /metrics) ───          ← not on dashboard
  vllm:num_requests_running                                  5.0
  vllm:num_requests_waiting                                  0.0
  vllm:kv_cache_usage_perc                                   0.027
  vllm:num_preemptions_total                                 0.0
```

**Reading each section**:

| Section | Key numbers | Meaning |
|---|---|---|
| Unified memory pool | `used` GiB; `GPU util` % | Same as dashboard panels 3 + 4 (compute). |
| vLLM container | `CPU=...`, `container-MEM=...` | Process-level only. vLLM's GPU allocation does NOT appear here. |
| vLLM internals | `num_requests_running`, `kv_cache_usage_perc`, `num_requests_waiting` | The most important per-request metrics — not on Grafana by default. |

**Override refresh**: `make watch-vllm interval=5` for 5-second updates.

### `make watch-vllm-load` — saturation-only, 1s refresh

Slimmer view for when you're actively driving load and want to know if
you're hitting limits. Includes inline threshold reminders so you don't have
to remember what "good" looks like. Sample:

```
14:32:17   vLLM LOAD watch (refresh 1s · Ctrl-C to exit)

── saturation signals (from vllm /metrics) ──────────────────
  vllm:num_requests_running                                  5.0
  vllm:num_requests_waiting                                  0.0
  vllm:kv_cache_usage_perc                                   0.027
  vllm:num_preemptions_total                                 0.0

── system pressure ──────────────────────────────────────────
  GPU util:    96%
  Mem used:    108544 MiB / 124688 MiB (87%)   avail: 14336 MiB

── thresholds ───────────────────────────────────────────────
  HEALTHY:   waiting=0   swapped=0   kv_cache<70%   gpu_util 95-100% in gen
  WARNING:   waiting<10   kv_cache 70-90%   preemptions ticking up
  CRITICAL:  waiting growing   kv_cache>90%   preemptions rising   mem>95%
```

**Reading**: each row is a saturation signal. Match the current values
against the three threshold lines. If everything matches HEALTHY, you have
headroom. If anything matches CRITICAL, the GPU is overloaded — back off
client-side concurrency or shrink the model.

### Which monitor to use when

| Situation | Use |
|---|---|
| Ambient "how's the box doing?" check | Grafana |
| Watching a load test in real time | `make watch-vllm-load` |
| Debugging a vLLM startup or load issue | `make watch-vllm` |
| Looking for trends across hours/days | Grafana (extend the time range) |
| Trying to spot a specific transient spike | Grafana, narrow the time range to 15 min |

## Ad-hoc command-line probes

Useful one-liners that don't need either Grafana or the watch scripts:

```bash
# Snapshot of GPU state (vendor tool, doesn't go through Prometheus)
nvidia-smi

# Live CPU/memory of ONE container
docker stats srv-vllm-1 --no-stream

# Continuous stream (refreshes ~1/sec; Ctrl-C to stop)
docker stats srv-vllm-1

# Raw vLLM metrics dump — every vllm:* gauge in one go
docker compose -f compose.inference.yml exec vllm \
  curl -s localhost:8000/metrics | grep '^vllm:' | head -30

# Gateway access log (who's hitting which endpoint)
docker compose -f compose.gateway.yml logs caddy --tail=50 -f

# Daily health summary (PASS/WARN/FAIL per check, exits non-zero on FAIL)
make health
```

## When a panel says "No data"

Quick triage — see [RUNBOOK.md](RUNBOOK.md) troubleshooting table for full
recipes.

| Panel(s) blank | Most likely cause |
|---|---|
| All panels | Prometheus down. `docker compose -f compose.observability.yml ps prometheus` |
| Per-container panels only | cAdvisor not enumerating. Check it's running v0.52+ (older versions break on cgroup v2) |
| GPU panels only | dcgm-exporter scrape issue. Check Prometheus targets page |
| One container missing from per-container panel | That container just started; wait 30s for next scrape |
| Old data shows up but no recent data | Prometheus is up but losing scrapes — check container network |

**Check what Prometheus thinks is up**:

```bash
docker compose -f compose.observability.yml exec prometheus \
  wget -qO- http://localhost:9090/api/v1/targets \
  | tr ',' '\n' | grep -E '"job"|"health"|"lastError"'
```

All four jobs (`prometheus`, `node`, `cadvisor`, `dcgm`) should report
`"health":"up"`. Any with `"lastError":"..."` populated is the broken one.

## Customizing the dashboards

Dashboards live in `observability/grafana/dashboards/*.json` and are
**provisioned** — meaning Grafana reloads them from those files on container
start. So:

- **Quick exploration**: edit live in Grafana, save changes. Survives until
  the grafana container is recreated (`make deploy` / `make up
  --force-recreate grafana`), then they revert to file.
- **Permanent changes**: edit the JSON file in this bundle, commit, push.
  Grafana picks them up on its next start.

To export current Grafana state back to JSON: dashboard's top-right menu →
**Share** → **Export** → **Save to file**. Drop the result into
`observability/grafana/dashboards/` and commit.

## Retention and storage

- Prometheus retains **15 days** of metric data (`--storage.tsdb.retention.time=15d`).
- Prometheus data lives in `/data/srv/data/prometheus/` (bind-mounted; ~1.5 GB
  steady state with the current scrape targets).
- Grafana state (saved dashboards, user accounts) lives in
  `/data/srv/data/grafana/` (~50 MB).

Both are durable directories, backed up by `make backup`. To extend
retention, edit `compose.observability.yml` and bump the
`--storage.tsdb.retention.time` flag — Prometheus will use about
~100 MB/day at this scrape configuration, so 30d ≈ 3 GB, 60d ≈ 6 GB.

## Behind the scenes — files you might touch

| File | Purpose |
|---|---|
| `compose.observability.yml` | Service definitions for Prometheus/Grafana/exporters |
| `observability/prometheus.yml` | Which exporters Prometheus scrapes (one entry per source) |
| `observability/grafana/dashboards/*.json` | Dashboard definitions (provisioned at startup) |
| `observability/grafana/provisioning/` | Datasource and dashboard auto-load config |
| `vllm-watch.sh` / `vllm-watch-load.sh` | Live command-line monitors |
| `health.sh` | Cron-friendly health checker (`make health`) |
