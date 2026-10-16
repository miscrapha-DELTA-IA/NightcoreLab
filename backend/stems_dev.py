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
TTL_SECONDS = 20 * 60
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
    try:
        command = [
            sys.executable, "-m", "demucs", "-n", "htdemucs",
            "--out", str(folder / "out"), str(source),
        ]
        result = subprocess.run(
            command, capture_output=True, text=True, timeout=720, check=False
        )
        if result.returncode != 0:
            raise RuntimeError("Demucs failed to separate the uploaded track")
        output = folder / "out" / "htdemucs" / "source"
        if not all((output / f"{stem}.wav").is_file() for stem in _stem_names):
            raise RuntimeError("Demucs did not produce all four source tracks")
        job["output"] = str(output)
        job["status"] = "ready"
    except (OSError, RuntimeError, subprocess.TimeoutExpired):
        job["status"] = "failed"
        job["message"] = "Stem processing failed or exceeded resource/time limits"
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
                         status="processing", created=time.monotonic(), message=None)
    asyncio.create_task(asyncio.to_thread(_process, job_id))
    return {"id": job_id, "status": "processing", "message": None}


@router.get("/api/stems/{job_id}")
async def stem_status(job_id: str, request: Request):
    _authorize(request)
    _cleanup()
    job = _jobs.get(job_id)
    if not job:
        raise HTTPException(404, "Job expired or unknown")
    return {"id": job["id"], "status": job["status"], "message": job["message"]}


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
