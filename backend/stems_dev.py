"""Optional, explicitly enabled dev-only HTDemucs four-stem worker.

Setup locally (not on a small public Render free instance):
    pip install demucs
    STEMS_DEV_ENABLED=1 STEMS_DEV_TOKEN=<long random secret> uvicorn main:app

An original audio file is accepted only with the explicit bearer token.
No cloud upload occurs unless the user enables the matching iOS dev switch.
This endpoint cannot promise real-time processing, GPU acceleration, or SLA.
"""
from __future__ import annotations

import asyncio
import hmac
import logging
import os
import secrets
import shutil
import subprocess
import sys
import tempfile
import time
from pathlib import Path

from fastapi import APIRouter, HTTPException, Request
from fastapi.responses import FileResponse

router = APIRouter()
_jobs: dict[str, dict] = {}
MAX_AUDIO = 35 * 1024 * 1024
TTL_SECONDS = 2 * 60 * 60
DEFAULT_TIMEOUT_SECONDS = 35 * 60
_logger = logging.getLogger("uvicorn.error")
_background_tasks: set[asyncio.Task] = set()
_ALLOWED_MODELS = {"htdemucs", "mdx_q"}


def _timeout_seconds() -> int:
    try:
        return min(3600, max(600, int(os.environ.get("STEMS_DEV_TIMEOUT_SECONDS", str(DEFAULT_TIMEOUT_SECONDS)))))
    except ValueError:
        return DEFAULT_TIMEOUT_SECONDS


def _model_name() -> str:
    selected = os.environ.get("STEMS_DEV_MODEL", "htdemucs").strip()
    return selected if selected in _ALLOWED_MODELS else "htdemucs"


def _demucs_command(folder: Path, source: Path) -> list[str]:
    return [sys.executable, "-m", "demucs", "-n", _model_name(),
            "--overlap", "0.1", "--shifts", "0", "-j", "1",
            "--segment", "7", "--out", str(folder / "out"), str(source)]
_stem_names = {"vocals", "other", "bass", "drums"}


def _authorize(request: Request) -> None:
    token = os.environ.get("STEMS_DEV_TOKEN", "")
    if os.environ.get("STEMS_DEV_ENABLED") != "1" or len(token) < 16:
        raise HTTPException(404, "Dev stem endpoint is disabled")
    supplied = request.headers.get("authorization", "")
    if not hmac.compare_digest(supplied, "Bearer " + token):
        raise HTTPException(401, "Unauthorized")


def _cleanup() -> None:
    now = time.monotonic()
    for job_id, job in tuple(_jobs.items()):
        if job["status"] == "processing":
            continue
        if now - job["created"] > TTL_SECONDS:
            shutil.rmtree(job["folder"], ignore_errors=True)
            _jobs.pop(job_id, None)


def _process(job_id: str) -> None:
    job = _jobs[job_id]
    folder = Path(job["folder"])
    source = folder / "source.m4a"
    model = job.get("model", "htdemucs")
    limit = job.get("timeout_seconds", _timeout_seconds())
    log_path = folder / "demucs.log"
    job["started"] = time.monotonic()
    try:
        # Persist logs on the Windows computer; do not buffer a long Demucs
        # progress stream in RAM or expose paths/tracebacks over the public API.
        command = _demucs_command(folder, source)
        command[command.index("-n") + 1] = model
        _logger.info("Demucs started job=%s model=%s deadline=%ds log=%s",
                     job_id, model, limit, log_path)
        with log_path.open("w", encoding="utf-8", errors="replace") as log:
            result = subprocess.run(command, stdout=log, stderr=subprocess.STDOUT,
                                    timeout=limit, check=False)
        if result.returncode != 0:
            job["message"] = ("Demucs falhou (código %d). Confira o demucs.log no PC; "
                              "não é erro de token nem de URL." % result.returncode)
            _logger.error("Demucs failed job=%s returncode=%s log=%s",
                          job_id, result.returncode, log_path)
            job["status"] = "failed"
            return
        output = folder / "out" / model / "source"
        if not all((output / f"{stem}.wav").is_file() for stem in _stem_names):
            job["message"] = "Demucs terminou sem gerar os quatro WAVs. Confira o demucs.log."
            _logger.error("Demucs incomplete output job=%s log=%s", job_id, log_path)
            job["status"] = "failed"
            return
        job["output"] = str(output)
        job["status"] = "ready"
        job["message"] = None
        _logger.info("Demucs complete job=%s in %.1fs", job_id,
                     time.monotonic() - job["started"])
    except subprocess.TimeoutExpired:
        job["status"] = "failed"
        job["message"] = ("Demucs excedeu %d minutos na CPU. Use uma faixa menor, "
                          "o perfil rápido mdx_q ou ajuste o limite do servidor." %
                          (limit // 60))
        _logger.error("Demucs timed out job=%s after %ds log=%s",
                      job_id, limit, log_path)
    except (OSError, RuntimeError) as exc:
        job["status"] = "failed"
        job["message"] = ("Erro local ao executar Demucs/FFmpeg. "
                          "Verifique o demucs.log e server-stderr.log no PC.")
        _logger.error("Demucs OS/runtime failure job=%s type=%s log=%s",
                      job_id, type(exc).__name__, log_path)
    finally:
        source.unlink(missing_ok=True)


@router.post("/api/stems", status_code=202)
async def submit_stems(request: Request):
    _authorize(request)
    _cleanup()
    if sum(job["status"] == "processing" for job in _jobs.values()) >= 1:
        raise HTTPException(429, "A development separation is already running")
    if request.headers.get("content-type") != "application/octet-stream":
        raise HTTPException(415, "Expected an audio/octet-stream source")
    if int(request.headers.get("content-length", "0") or 0) > MAX_AUDIO:
        raise HTTPException(413, "Audio exceeds dev limit")
    folder = Path(tempfile.mkdtemp(prefix="nightcore-stems-"))
    source = folder / "source.m4a"
    size = 0
    try:
        with source.open("wb") as destination:
            async for chunk in request.stream():
                size += len(chunk)
                if size > MAX_AUDIO:
                    raise HTTPException(413, "Audio exceeds dev limit")
                destination.write(chunk)
        if size == 0:
            raise HTTPException(400, "Empty audio")
    except BaseException:
        shutil.rmtree(folder, ignore_errors=True)
        raise
    job_id = secrets.token_hex(12)
    _jobs[job_id] = dict(id=job_id, folder=str(folder),
                         status="processing", created=time.monotonic(), message=None,
                         model=_model_name(), timeout_seconds=_timeout_seconds())
    # Retain the task until it completes: asyncio warns fire-and-forget tasks
    # can be garbage collected if the event loop holds only weak references.
    task = asyncio.create_task(asyncio.to_thread(_process, job_id))
    _background_tasks.add(task)
    task.add_done_callback(_background_tasks.discard)
    return {"id": job_id, "status": "processing", "message": None}


@router.get("/api/stems/{job_id}")
async def stem_status(job_id: str, request: Request):
    _authorize(request)
    _cleanup()
    job = _jobs.get(job_id)
    if not job:
        raise HTTPException(404, "Job expired or unknown")
    return {"id": job["id"], "status": job["status"], "message": job["message"],
            "elapsed_seconds": int(time.monotonic() - job["created"]),
            "timeout_seconds": job["timeout_seconds"],
            "model": job["model"]}


@router.get("/api/stems/{job_id}/{stem}")
async def download_stem(job_id: str, stem: str, request: Request):
    _authorize(request)
    _cleanup()
    job = _jobs.get(job_id)
    if not job or job["status"] != "ready" or stem not in _stem_names:
        raise HTTPException(404, "Stem is not ready")
    path = Path(job["output"]) / f"{stem}.wav"
    if not path.is_file():
        raise HTTPException(404, "Stem not available")
    return FileResponse(path, media_type="audio/wav", filename=f"{stem}.wav")
