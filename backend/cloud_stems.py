"""Free-only admission control; audio travels directly between iPhone and ZeroGPU.

No inference SDK, GPU provisioning, HF token or paid-provider fallback exists here.
The local SQLite budget is advisory: Render can replace its ephemeral disk on
restart, deploy or idle spin-down. The anonymous provider quota is the billing guard.
"""
from __future__ import annotations

import hashlib
import asyncio
from contextlib import closing
import hmac
import os
import re
import secrets
import sqlite3
import json
import threading
import tempfile
import time
import urllib.request
from pathlib import Path
from dataclasses import dataclass

from fastapi import APIRouter, HTTPException, Request
from pydantic import BaseModel, Field

from zerogpu_space.tickets import GPU_SECONDS, MAX_BYTES, MAX_SECONDS, MODEL, issue

router = APIRouter(prefix="/v1/stems/cloud")
COMMUNITY_URL = "https://d-r-e-audio-separator.hf.space"
COMMUNITY_MODEL = "bs-roformer-musdb18hq"
COMMUNITY_REVISION = "bbfd93e5fcc5bccd7b09fe41259c0902b266308a"
_runtime_secret = secrets.token_urlsafe(32)
_community_lock = threading.Lock()
_community_health: tuple[float, bool] = (0, False)


def _community_runtime_ready() -> bool:
    """Fail closed if the audited public app changes or leaves ZeroGPU."""
    global _community_health
    with _community_lock:
        now = time.monotonic()
        if now < _community_health[0]:
            return _community_health[1]
        ready = False
        try:
            with urllib.request.urlopen("https://huggingface.co/api/spaces/D-r-e/audio-separator", timeout=5) as response:
                payload = response.read(200_001)
            if len(payload) <= 200_000:
                data = json.loads(payload)
                runtime = data.get("runtime", {})
                ready = (data.get("sha") == COMMUNITY_REVISION
                         and runtime.get("sha", COMMUNITY_REVISION) == COMMUNITY_REVISION
                         and data.get("sdk") == "gradio"
                         and runtime.get("stage") == "RUNNING"
                         and runtime.get("hardware", {}).get("current") == "zero-a10g")
        except (OSError, ValueError, TypeError, AttributeError):
            pass
        _community_health = (now + (300 if ready else 15), ready)
        return ready


@dataclass(frozen=True)
class CloudConfiguration:
    url: str
    secret: str
    beta: str
    provider: str
    model: str


def configuration() -> CloudConfiguration | None:
    url = os.getenv("STEMS_CLOUD_SPACE_URL", "").rstrip("/")
    secret = os.getenv("STEMS_CLOUD_SIGNING_KEY", "")
    beta = os.getenv("STEMS_CLOUD_BETA_CODE", "")
    provider = os.getenv("STEMS_CLOUD_PROVIDER", "owned_htdemucs")
    if (os.getenv("STEMS_CLOUD_ENABLED") != "1"
            or os.getenv("STEMS_CLOUD_FREE_ONLY", "1") != "1"
            or not re.fullmatch(r"https://[a-z0-9]+(?:-[a-z0-9]+)*\.hf\.space", url)
            or provider not in {"owned_htdemucs", "community_bs_roformer"}):
        return None
    if provider == "community_bs_roformer":
        # This is an already public, anonymous ZeroGPU API, not an account-owned
        # paid resource. A beta code is optional; no HF credential is accepted.
        if url != COMMUNITY_URL or (beta and len(beta) < 16):
            return None
        return CloudConfiguration(url, _runtime_secret, beta, provider, COMMUNITY_MODEL)
    if len(secret) < 32 or len(beta) < 16:
        return None
    return CloudConfiguration(url, secret, beta, provider, MODEL)


class Admission(BaseModel):
    sha256: str = Field(pattern=r"^[a-f0-9]{64}$")
    bytes: int = Field(gt=0, le=MAX_BYTES)
    seconds: float = Field(gt=0, lt=MAX_SECONDS, allow_inf_nan=False)


@router.get("")
async def status():
    config = configuration()
    available = None
    if config and config.provider == "community_bs_roformer":
        available = await asyncio.to_thread(_community_runtime_ready)
    return {"enabled": config is not None, "free_only": True,
            "provider_available": available,
            "provider": config.provider if config else None,
            "requires_beta_code": bool(config.beta) if config else True,
            "model": config.model if config else MODEL,
            "max_bytes": MAX_BYTES, "max_seconds": MAX_SECONDS,
            "max_gpu_seconds": GPU_SECONDS}


def _reserve(secret: str, address: str) -> None:
    # Small synchronous transaction, no network/file payloads/model work here.
    database = Path(os.getenv("STEMS_CLOUD_BUDGET_DB",
                              str(Path(tempfile.gettempdir()) / "gnarly-cloud-budget.sqlite3")))
    now = time.time()
    client = hmac.new(secret.encode(), address.encode(), hashlib.sha256).hexdigest()
    # Hard ceilings cannot be raised accidentally via environment variables.
    try:
        daily = min(2, max(1, int(os.getenv("STEMS_CLOUD_DAILY_JOBS", "2"))))
    except ValueError:
        daily = 1
    with closing(sqlite3.connect(database, timeout=2)) as db, db:
        db.execute("CREATE TABLE IF NOT EXISTS admissions (created REAL, client TEXT)")
        db.execute("BEGIN IMMEDIATE")
        db.execute("DELETE FROM admissions WHERE created <= ?", (now - 86400,))
        if db.execute("SELECT COUNT(*) FROM admissions").fetchone()[0] >= daily:
            raise HTTPException(429, "Limite diário do beta atingido. Tente amanhã ou use o iPhone.")
        latest = db.execute("SELECT MAX(created) FROM admissions").fetchone()[0]
        if latest is not None and now - latest < 900:
            raise HTTPException(429, "Já existe uma autorização recente. Aguarde 15 minutos.")
        db.execute("INSERT INTO admissions VALUES (?, ?)", (now, client))


@router.post("/ticket")
async def authorize(body: Admission, request: Request):
    config = configuration()
    if config is None:
        raise HTTPException(503, "GPU gratuita ainda não configurada. Use a separação no iPhone.")
    if config.beta and not hmac.compare_digest(request.headers.get("authorization", ""), "Bearer " + config.beta):
        raise HTTPException(401, "Código do beta inválido. Configure-o em Servidor.")
    if config.provider == "community_bs_roformer":
        if not await asyncio.to_thread(_community_runtime_ready):
            raise HTTPException(503, "O Space comunitário está indisponível ou foi atualizado. Tente mais tarde ou use o iPhone.")
    try:
        _reserve(config.secret, request.client.host if request.client else "unknown")
    except sqlite3.Error:
        raise HTTPException(503, "Controle de limites indisponível; separação bloqueada.") from None
    claims = {"id": secrets.token_hex(16), "aud": config.url, "exp": int(time.time()) + 900,
              "model": config.model, "sha256": body.sha256, "bytes": body.bytes, "seconds": body.seconds}
    return {"ticket": issue(config.secret, claims), "space_url": config.url, "model": config.model,
            "provider": config.provider,
            "max_gpu_seconds": GPU_SECONDS}
