# apex-spark-01 service stack — one interface for everything.
#   make up            bring the whole stack up (correct order)
#   make down          stop everything
#   make logs svc=vllm follow logs for one service
#   make ps            status
#   make deploy        pull + recreate (use after git pull)
#   make models        pull the default Ollama models

# Use bash for recipes — required for brace expansion (mkdir -p /a/{b,c}) which
# /bin/sh (dash on Ubuntu) does NOT support. Without this, recipes create
# literal directories named "{b,c}".
SHELL := /bin/bash

CORE      := -f docker-compose.yml
INFER     := -f compose.inference.yml
GATEWAY   := -f compose.gateway.yml
APPS      := -f compose.apps.yml
OBS       := -f compose.observability.yml
COMPOSE   := docker compose $(CORE) $(INFER) $(GATEWAY) $(APPS) $(OBS)

.PHONY: init up down restart logs ps pull deploy models gpu health rebalance vllm-stop vllm-start backup prune prune-status install-system download-models pull-stack watch-vllm

# Create the bind-mount directories before first `up`. Run once.
# Postgres/MinIO run as root then drop privileges, so root-owned dirs are fine;
# Redis runs as uid 999 and needs ownership of its dir.
init:
	sudo mkdir -p /data/srv/data/{postgres,redis,qdrant,qdrant-snapshots,minio,caddy,caddy-config,prometheus,grafana,open-webui}
	sudo mkdir -p /data/models/{hf-cache,ollama,shared,local}
	sudo mkdir -p /data/home
	sudo chown -R 999:999 /data/srv/data/redis
	sudo chown -R 65534:65534 /data/srv/data/prometheus   # prometheus runs as nobody
	sudo chown -R 472:472 /data/srv/data/grafana          # grafana runs as uid 472
	sudo chown -R 1000:1000 /data/srv/data/open-webui     # open-webui runs as uid 1000
	sudo groupadd -f ml-users
	sudo chgrp ml-users /data/models/shared /data/models/hf-cache /data/models/ollama /data/models/local
	sudo chmod 2775     /data/models/shared /data/models/hf-cache /data/models/ollama /data/models/local
	@echo "data dirs created. Add users with: sudo usermod -aG ml-users <user>"
	@echo "Now: cp .env.example .env && edit, then make up"

# Bring-up order matters: core data services, THEN vLLM (stakes its memory),
# THEN ollama + tei + gateway + apps.
up:
	docker compose $(CORE) up -d
	docker compose $(INFER) up -d vllm
	@echo "waiting for vLLM to allocate + load model..."
	@until docker compose $(INFER) exec -T vllm curl -fsS localhost:8000/health >/dev/null 2>&1; do sleep 5; done
	docker compose $(INFER) up -d ollama tei
	docker compose $(GATEWAY) $(APPS) $(OBS) up -d
	@echo "stack up."

down:
	$(COMPOSE) down

restart:
	$(COMPOSE) restart $(svc)

logs:
	$(COMPOSE) logs -f $(svc)

ps:
	$(COMPOSE) ps

pull:
	$(COMPOSE) pull

deploy: pull
	$(MAKE) up

# Pre-download HF models into /data/models/hf-cache so vLLM/TEI find them on
# first start. Uses VLLM_MODEL + TEI_MODEL from .env; pass IDs to override.
# Retries + logs to ~/hf-download.log. Safe to run any time, idempotent.
download-models:
	./download-models.sh $(models)

# Pull every stack image via skopeo (works through corp proxies where
# `docker pull` fails). Idempotent; needs NGC_API_KEY for nvcr.io images.
pull-stack:
	./skopeo-pull-stack.sh $(images)

# Default Ollama models — sized to stay in the 25% (~28GB) slice (1 loaded at a time).
models:
	docker compose $(INFER) exec ollama ollama pull gemma3:4b
	docker compose $(INFER) exec ollama ollama pull qwen2.5:7b
	docker compose $(INFER) exec ollama ollama pull qwen2.5:32b

gpu:
	nvidia-smi

# Live vLLM monitor — GPU, container, KV cache, queue depth. Ctrl-C to exit.
# Default refresh 2s; override with `make watch-vllm interval=5`.
watch-vllm:
	./vllm-watch.sh $(interval)

# Daily health checks: services, GPU, disk, /data quotas, inference endpoints.
# PASS/WARN/FAIL output; exits non-zero on any FAIL (usable from cron).
health:
	./health.sh

# pg_dump + qdrant snapshot + restic of durable data/config. Off-box push only
# if RESTIC_REPO is set in .env (otherwise stages locally). See RUNBOOK.md.
backup:
	./backup.sh

# Reclaim /var/lib/docker space: images unused for 14d + build cache + stopped
# containers. In-use images are kept. Safe to run anytime / on a schedule.
prune:
	docker image prune -af --filter "until=336h"
	docker builder prune -af
	docker container prune -f
	@echo "── docker space after prune ──"; docker system df

# Read-only: docker disk usage, RECLAIMABLE column = what `make prune` would free.
prune-status:
	@docker system df
	@echo; echo "── largest images ──"
	@docker image ls --format '{{.Size}}\t{{.Repository}}:{{.Tag}}' | sort -h | tail -n 15

# Install host hygiene: docker log rotation (merged) + journald cap. Needs root.
install-system:
	sudo ./install-system.sh

# ── memory split between vLLM and Ollama ──────────────────────────────────
# Shift the partition: set vLLM's share of the 128GB pool and reload it.
# Ollama auto-uses whatever vLLM leaves free. Usage: make rebalance util=0.50
rebalance:
	@test -n "$(util)" || { echo "usage: make rebalance util=0.50"; exit 1; }
	@sed -i "s/^VLLM_GPU_UTIL=.*/VLLM_GPU_UTIL=$(util)/" .env
	@echo "VLLM_GPU_UTIL set to $(util) — restarting vLLM..."
	docker compose $(INFER) up -d --force-recreate vllm
	@echo "done. Ollama will pick up freed memory on its next model load."

# Temporarily free vLLM's whole slice for a one-off large Ollama job.
vllm-stop:
	docker compose $(INFER) stop vllm
	@echo "vLLM stopped — full pool available to Ollama."

vllm-start:
	docker compose $(INFER) up -d vllm
	@echo "vLLM restarted — reclaiming its VLLM_GPU_UTIL slice."
