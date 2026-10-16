"""Isolated, opt-in NightcoreLab HTDemucs development worker.

Runs independently of the production yt-dlp/Render backend:
    uvicorn demucs_app:app --host 127.0.0.1 --port 8765

Only /health is unauthenticated. All /api/stems endpoints enforce the long
STEMS_DEV_TOKEN bearer token in stems_dev.py. Never run with no token.
"""
from __future__ import annotations

import os
from fastapi import FastAPI
from stems_dev import router as stem_router, _model_name, _timeout_seconds

app = FastAPI(title="NightcoreLab HTDemucs Dev", version="1.0.0")
app.include_router(stem_router)

@app.get("/health")
def health():
    return {
        "status": "ok",
        "service": "nightcorelab-demucs-dev",
        "model": _model_name(),
        "timeout_seconds": _timeout_seconds(),
        "enabled": os.getenv("STEMS_DEV_ENABLED") == "1",
    }
