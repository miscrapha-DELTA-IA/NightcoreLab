"""GNARLY audio node for an always-on Windows PC.

The PC initiates every HTTPS connection. No local ports or tunnel required.
Run after installing the Windows environment with setup.ps1. This node is
strictly a requested-video audio worker, never an open URL proxy.
"""
from __future__ import annotations

import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import time
import unicodedata
from urllib.error import HTTPError, URLError
from urllib.request import Request, urlopen

ROOT = Path(__file__).resolve().parent
ID = re.compile(r"^[A-Za-z0-9_-]{11}$")
MAX_AUDIO = 25 * 1024 * 1024
BACKEND = "https://nightcorelab.onrender.com"


def load_config() -> tuple[str, str]:
    path = ROOT / "node.env"
    values = {}
    if path.is_file():
        for line in path.read_text("utf-8").splitlines():
            if "=" in line and not line.lstrip().startswith("#"):
                key, value = line.split("=", 1)
                values[key.strip()] = value.strip()
    token = os.getenv("GNARLY_PC_NODE_TOKEN") or values.get("GNARLY_PC_NODE_TOKEN", "")
    url = os.getenv("GNARLY_BACKEND_URL") or values.get("GNARLY_BACKEND_URL", BACKEND)
    if len(token) < 40:
        raise RuntimeError("Falta GNARLY_PC_NODE_TOKEN no node.env")
    if url.rstrip("/") != BACKEND:
        raise RuntimeError("Backend não autorizado; use " + BACKEND)
    return BACKEND, token


def api(method: str, path: str, token: str, *, data=None, headers=None, timeout=30):
    extra = {"Authorization": "Bearer " + token, "Accept": "application/json",
             **(headers or {})}
    if data is not None:
        extra["Content-Type"] = "audio/mp4" if method == "PUT" else "application/json"
    request = Request(BACKEND + path, data=data, headers=extra, method=method)
    with urlopen(request, timeout=timeout) as response:
        body = response.read(8192)
        if response.status == 204:
            return None
        return json.loads(body)


def extract(video_id: str, directory: Path) -> Path | None:
    if not ID.fullmatch(video_id):
        return None
    target = directory / (video_id + ".m4a")
    args = [sys.executable, "-m", "yt_dlp",
            "--no-playlist", "--no-overwrites", "--no-part",
            "--no-warnings", "--no-progress", "--no-call-home",
            "--socket-timeout", "12", "--retries", "0",
            "--extractor-retries", "0",
            "--match-filter", "duration < 600",
            "--format", "bestaudio[ext=m4a]",
            "--output", str(directory / (video_id + ".%(ext)s")),
            "https://www.youtube.com/watch?v=" + video_id]
    try:
        # Kill a stalled extractor instead of freezing the always-on agent.
        done = subprocess.run(args, timeout=75, check=False,
                              stdin=subprocess.DEVNULL, capture_output=True)
        if done.returncode != 0 or not target.is_file():
            return None
        size = target.stat().st_size
        if size < 1024 or size > MAX_AUDIO:
            return None
        with target.open("rb") as file:
            header = file.read(12)
        return target if len(header)>=12 and header[4:8]==b"ftyp" else None
    except (subprocess.TimeoutExpired, OSError):
        return None


def worker(*, once=False) -> int:
    _, token = load_config()
    print("GNARLY PC Audio Node • conexão de saída segura • sem portas abertas", flush=True)
    while True:
        try:
            job = api("GET", "/pc-node/next", token, timeout=20)
            if not job:
                if once:
                    print("Conexão autenticada com o Render: OK (nenhum trabalho).",flush=True)
                    return 0
                time.sleep(3)
                continue
            video_id, lease = job.get("video_id"), job.get("lease")
            if not ID.fullmatch(str(video_id or "")) or not isinstance(lease,str):
                raise ValueError("Trabalho inválido")
            print("Preparando gravação " + video_id,flush=True)
            with tempfile.TemporaryDirectory(prefix="gnarly-pc-") as tmp:
                file = extract(video_id, Path(tmp))
                if file is None:
                    print("Origem indisponível para " + video_id,flush=True)
                    api("POST", "/pc-node/fail/" + video_id, token,
                        headers={"X-Gnarly-Lease": lease},timeout=20)
                    continue
                # Upload is explicitly bounded; nothing from R2 or the account
                # is sent to this computer. Content goes to Render over HTTPS.
                data = file.read_bytes()
                api("PUT", "/pc-node/upload/" + video_id, token, data=data,
                    headers={"X-Gnarly-Lease":lease,"X-Gnarly-Title":video_id},
                    timeout=90)
                print("Áudio validado e enviado ao cache: " + video_id,flush=True)
            if once:
                return 0
        except (HTTPError, URLError, TimeoutError, ValueError, OSError) as error:
            if isinstance(error, HTTPError) and error.code in (401,403):
                print("Token de autenticação inválido no servidor Render.",flush=True)
                return 2
            print("Falha de conexão com o backend, nova tentativa controlada: " +
                  type(error).__name__,flush=True)
            if once:
                return 1
            time.sleep(7)


if __name__=="__main__":
    try:
        sys.exit(worker(once="--once" in sys.argv))
    except RuntimeError as error:
        print(error)
        sys.exit(2)
