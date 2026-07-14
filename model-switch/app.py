"""
model-switch: OpenAI-compatible router that fronts multiple vLLM backends and
enforces a single-active-model policy.

Behavior:
  - /v1/models always advertises every configured model (so all show in UI pickers).
  - A request whose "model" field matches the active backend proxies through.
  - A request for a DIFFERENT model triggers a stop+start swap of the vLLM
    container, but only if no requests are currently in flight.
  - If in-flight requests exist on a different model, or another swap is
    already running, the request is rejected with 409.

Containers are addressed via the host Docker socket (mounted read-write).
This is only safe on a single-tenant box — the socket grants root-equivalent
access to the host.
"""
import asyncio
import json
import logging
import os
from contextlib import asynccontextmanager

import docker
import httpx
from docker.errors import NotFound as ContainerNotFound
from fastapi import FastAPI, HTTPException, Request
from fastapi.responses import StreamingResponse
from starlette.background import BackgroundTask

log = logging.getLogger("model-switch")
logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s %(levelname)s %(name)s %(message)s",
)

# ── configuration ──
# Model slots are populated from env vars. Each slot needs three values:
#   <SLOT>_MODEL_NAME  — the OpenAI-API `model` string clients send
#                        (must match vLLM's --served-model-name for that backend)
#   <SLOT>_CONTAINER   — the Docker container name (as Compose names it)
#   <SLOT>_UPSTREAM    — the http://... base URL on the internal network
MODELS: dict[str, dict] = {}
for slot in ("TEXT", "VL"):
    name = os.environ.get(f"{slot}_MODEL_NAME")
    container = os.environ.get(f"{slot}_CONTAINER")
    upstream = os.environ.get(f"{slot}_UPSTREAM")
    if not (name and container and upstream):
        log.warning("slot %s not fully configured; skipping", slot)
        continue
    MODELS[name] = {"container": container, "upstream": upstream, "slot": slot}

if not MODELS:
    raise RuntimeError(
        "no models configured; set at least TEXT_MODEL_NAME / TEXT_CONTAINER / TEXT_UPSTREAM"
    )

READY_TIMEOUT_S = int(os.environ.get("READY_TIMEOUT_S", "300"))
READY_POLL_S = float(os.environ.get("READY_POLL_S", "2"))

log.info("configured models: %s", list(MODELS.keys()))
log.info("ready-timeout=%ss, poll=%ss", READY_TIMEOUT_S, READY_POLL_S)

# ── state ──
class State:
    def __init__(self):
        self.active: str | None = None
        self.in_flight: int = 0
        self.is_switching: bool = False
        self.lock = asyncio.Lock()

state = State()
docker_client = docker.from_env()

# ── lifecycle ──
@asynccontextmanager
async def lifespan(app: FastAPI):
    # Detect whichever vLLM is already running, so we don't kick it on startup.
    for name, spec in MODELS.items():
        try:
            c = docker_client.containers.get(spec["container"])
            if c.status == "running":
                state.active = name
                log.info("detected running backend at startup: %s (%s)", name, spec["container"])
                break
        except ContainerNotFound:
            pass
    if state.active is None:
        log.info("no backend running at startup; first request will start one")
    yield

app = FastAPI(title="model-switch", lifespan=lifespan)

# ── helpers ──
async def _wait_ready(url: str) -> bool:
    deadline = asyncio.get_event_loop().time() + READY_TIMEOUT_S
    async with httpx.AsyncClient(timeout=5.0) as client:
        while asyncio.get_event_loop().time() < deadline:
            try:
                r = await client.get(f"{url}/health")
                if r.status_code == 200:
                    return True
            except Exception:
                pass
            await asyncio.sleep(READY_POLL_S)
    return False

async def _stop_container(name: str):
    try:
        c = docker_client.containers.get(name)
        if c.status == "running":
            log.info("stopping container %s", name)
            c.stop(timeout=30)
    except ContainerNotFound:
        log.warning("container %s not found on stop", name)

async def _start_container(name: str):
    try:
        c = docker_client.containers.get(name)
        log.info("starting container %s (current status: %s)", name, c.status)
        c.start()
    except ContainerNotFound:
        raise HTTPException(
            500,
            f"container {name} not defined; is compose.inference.yml up to date?",
        )

async def _do_switch(target: str, previous: str | None):
    log.info("switch: %s -> %s", previous, target)
    if previous:
        await _stop_container(MODELS[previous]["container"])
    await _start_container(MODELS[target]["container"])
    if not await _wait_ready(MODELS[target]["upstream"]):
        raise HTTPException(
            504,
            f"{target} did not become ready within {READY_TIMEOUT_S}s",
        )

async def _acquire_slot(target: str):
    """Reserve a request slot for `target`. Triggers a switch if needed.

    Raises 409 if a switch would preempt in-flight requests, or if another
    switch is already in progress.
    """
    async with state.lock:
        if state.is_switching:
            raise HTTPException(
                status_code=409,
                detail={
                    "error": "model_switch_in_progress",
                    "message": "a model swap is already in progress; retry shortly",
                },
            )
        if state.active == target:
            state.in_flight += 1
            return
        if state.in_flight > 0:
            raise HTTPException(
                status_code=409,
                detail={
                    "error": "model_locked",
                    "active_model": state.active,
                    "requested_model": target,
                    "in_flight": state.in_flight,
                    "message": (
                        f"'{state.active}' has {state.in_flight} in-flight "
                        f"request(s); cannot switch to '{target}' now. Wait "
                        f"for them to complete, then retry."
                    ),
                },
            )
        # Nothing in flight, different model requested → do the swap.
        # Hold is_switching=True across the swap so concurrent requests 409.
        state.is_switching = True
        previous = state.active

    try:
        await _do_switch(target, previous)
    except Exception:
        async with state.lock:
            state.is_switching = False
        raise

    async with state.lock:
        state.active = target
        state.is_switching = False
        state.in_flight += 1

async def _release_slot():
    async with state.lock:
        state.in_flight = max(0, state.in_flight - 1)

# ── endpoints ──
@app.get("/health")
async def health():
    return {
        "status": "ok",
        "active_model": state.active,
        "in_flight": state.in_flight,
        "is_switching": state.is_switching,
        "known_models": list(MODELS.keys()),
    }

@app.get("/v1/models")
async def list_models():
    # Always report all configured models, regardless of which is loaded, so
    # every model appears in Open WebUI's picker.
    return {
        "object": "list",
        "data": [
            {"id": n, "object": "model", "owned_by": "local"}
            for n in MODELS.keys()
        ],
    }

async def _proxy(target: str, path: str, request: Request, body: bytes) -> StreamingResponse:
    upstream = MODELS[target]["upstream"]
    url = f"{upstream}/v1/{path}"
    fwd_headers = {
        k: v for k, v in request.headers.items()
        if k.lower() not in ("host", "content-length")
    }

    client = httpx.AsyncClient(timeout=None)
    try:
        req = client.build_request(
            request.method, url,
            content=body,
            headers=fwd_headers,
            params=request.query_params,
        )
        r = await client.send(req, stream=True)
    except Exception:
        await client.aclose()
        raise

    async def cleanup():
        try:
            await r.aclose()
        finally:
            await client.aclose()
            await _release_slot()

    return StreamingResponse(
        r.aiter_raw(),
        status_code=r.status_code,
        headers={
            k: v for k, v in r.headers.items()
            if k.lower() not in ("content-length", "transfer-encoding", "connection")
        },
        background=BackgroundTask(cleanup),
    )

@app.api_route("/v1/{path:path}", methods=["GET", "POST", "PUT", "DELETE"])
async def route(path: str, request: Request):
    # /v1/models handled by dedicated endpoint above (path=models, method=GET).
    # Everything else needs a model field to route correctly.
    body = await request.body()
    target = None
    if body:
        try:
            payload = json.loads(body)
            if isinstance(payload, dict):
                target = payload.get("model")
        except json.JSONDecodeError:
            pass

    if target is None:
        # No model field: only allow if there's a current active model AND this
        # is a GET (e.g. /v1/models/{id}). POSTs without model are ambiguous.
        if request.method != "GET":
            raise HTTPException(400, "request body must include 'model' field")
        if state.active is None:
            raise HTTPException(503, "no active model — POST with a 'model' field first")
        target = state.active

    if target not in MODELS:
        raise HTTPException(
            400,
            detail={
                "error": "unknown_model",
                "requested": target,
                "known": list(MODELS.keys()),
            },
        )

    await _acquire_slot(target)
    try:
        return await _proxy(target, path, request, body)
    except Exception:
        await _release_slot()
        raise
