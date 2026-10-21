"""Free-only admission control; audio travels directly between iPhone and ZeroGPU.

No inference SDK, GPU provisioning, HF token or paid-provider fallback exists here.
The local SQLite budget is advisory: Render can replace its ephemeral disk on
restart, deploy or idle spin-down. The anonymous provider quota is the billing guard.
"""
from __future__ import annotations

import hashlib
import hmac
import os
import re
import secrets
import sqlite3
import tempfile
import time
from pathlib import Path

from fastapi import APIRouter, HTTPException, Request
from pydantic import BaseModel, Field

from zerogpu_space.tickets import GPU_SECONDS, MAX_BYTES, MAX_SECONDS, MODEL, issue

router = APIRouter(prefix="/v1/stems/cloud")


def configuration() -> tuple[str, str, str] | None:
    url = os.getenv("STEMS_CLOUD_SPACE_URL", "").rstrip("/")
    secret = os.getenv("STEMS_CLOUD_SIGNING_KEY", "")
    beta = os.getenv("STEMS_CLOUD_BETA_CODE", "")
    if (os.getenv("STEMS_CLOUD_ENABLED") != "1"
            or os.getenv("STEMS_CLOUD_FREE_ONLY", "1") != "1"
            or not re.fullmatch(r"https://[a-z0-9]+(?:-[a-z0-9]+)*\.hf\.space", url)
            or len(secret) < 32 or len(beta) < 16):
        return None
    return url, secret, beta


class Admission(BaseModel):
    sha256: str = Field(pattern=r"^[a-f0-9]{64}$")
    bytes: int = Field(gt=0, le=MAX_BYTES)
    seconds: float = Field(gt=0, lt=MAX_SECONDS, allow_inf_nan=False)


@router.get("")
async def status():
    return {"enabled": configuration() is not None, "free_only": True,
            "model": MODEL, "max_bytes": MAX_BYTES, "max_seconds": MAX_SECONDS,
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
    with sqlite3.connect(database, timeout=2) as db:
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
    url, secret, beta = config
    if not hmac.compare_digest(request.headers.get("authorization", ""), "Bearer " + beta):
        raise HTTPException(401, "Código do beta inválido. Configure-o em Servidor.")
    try:
        _reserve(secret, request.client.host if request.client else "unknown")
    except sqlite3.Error:
        raise HTTPException(503, "Controle de limites indisponível; separação bloqueada.") from None
    claims = {"id": secrets.token_hex(16), "aud": url, "exp": int(time.time()) + 900,
              "model": MODEL, "sha256": body.sha256, "bytes": body.bytes, "seconds": body.seconds}
    return {"ticket": issue(secret, claims), "space_url": url, "model": MODEL,
            "max_gpu_seconds": GPU_SECONDS}
