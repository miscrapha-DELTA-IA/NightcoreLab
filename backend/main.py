"""
Nightcore Lab — ponte de extração de áudio para o app iOS.

Nada fica guardado: cada pedido usa um diretório temporário próprio,
o .m4a é enviado direto na resposta e a pasta é apagada assim que o envio termina.

Rodar localmente:
    pip install -r requirements.txt
    uvicorn main:app --host 0.0.0.0 --port 8000

No Render (Root Directory = backend):
    Build:  pip install -r requirements.txt
    Start:  uvicorn main:app --host 0.0.0.0 --port $PORT

YouTube exige um runtime de JavaScript desde o yt-dlp 2025.11.12: o requirements.txt
instala "yt-dlp[default]" (traz o yt-dlp-ejs) e o pacote "deno" (binário oficial do Deno).

Variáveis de ambiente opcionais:
    MAX_DURATION_SECONDS      duração máxima por faixa (padrão 1200 = 20 min)
    MAX_CONCURRENT_DOWNLOADS  extrações simultâneas (padrão 2; protege os 512 MB do tier gratuito)
    COOKIES_FILE              caminho de um cookies.txt (formato Netscape) para contornar a
                              verificação anti-bot do YouTube. No Render, use um Secret File:
                              /etc/secrets/cookies.txt
"""

from __future__ import annotations

import importlib.util
import logging
import os
import re
import shutil
import tempfile
import threading
import time
from pathlib import Path
from urllib.parse import urlparse

import yt_dlp
from fastapi import BackgroundTasks, FastAPI, HTTPException
from fastapi.responses import FileResponse
from pydantic import BaseModel, HttpUrl

MAX_DURATION_SECONDS = int(os.getenv("MAX_DURATION_SECONDS", "1200"))
MAX_CONCURRENT_DOWNLOADS = int(os.getenv("MAX_CONCURRENT_DOWNLOADS", "2"))
COOKIES_FILE = os.getenv("COOKIES_FILE", "").strip()

# Commit publicado (o Render define RENDER_GIT_COMMIT em cada deploy).
DEPLOYED_COMMIT = os.getenv("RENDER_GIT_COMMIT", "")[:7]

# Reaproveita o logger do uvicorn: as mensagens aparecem nos logs do Render.
log = logging.getLogger("uvicorn.error")

WORK_DIR_PREFIX = "nightcore_"
# Pastas mais velhas que isso são restos de envios interrompidos (cliente desconectou
# no meio, servidor reiniciou...) e podem ser apagadas com segurança.
STALE_AFTER_SECONDS = 30 * 60

# Só aceita links do YouTube: impede que o servidor vire um proxy genérico de downloads.
ALLOWED_HOSTS = {
    "youtube.com",
    "www.youtube.com",
    "m.youtube.com",
    "music.youtube.com",
    "youtu.be",
}

_download_slots = threading.BoundedSemaphore(MAX_CONCURRENT_DOWNLOADS)

app = FastAPI(
    title="Nightcore Lab Bridge",
    description="Extrai o áudio de um link do YouTube em .m4a e o envia direto, sem armazenar.",
    version="1.2.0",
)


class DownloadRequest(BaseModel):
    url: HttpUrl


@app.api_route("/", methods=["GET", "HEAD"])
def health():
    """Health check. Aceita HEAD para monitores de uptime; também 'acorda' o Render."""
    return {
        "status": "ok",
        "version": app.version,
        "commit": DEPLOYED_COMMIT,
        "ffmpeg": shutil.which("ffmpeg") is not None,
        "yt_dlp": yt_dlp.version.__version__,
        # Runtime de JavaScript + componente EJS: necessários para o YouTube.
        "deno": shutil.which("deno") is not None,
        "ejs": importlib.util.find_spec("yt_dlp_ejs") is not None,
        "cookies": bool(COOKIES_FILE) and os.path.isfile(COOKIES_FILE),
    }


@app.post("/download")
def download(request: DownloadRequest, background_tasks: BackgroundTasks):
    # Função síncrona de propósito: o FastAPI a executa num thread pool,
    # então o yt-dlp (bloqueante) não trava o servidor para outros pedidos.
    url = str(request.url)
    host = (urlparse(url).hostname or "").lower()
    if host not in ALLOWED_HOSTS:
        raise HTTPException(status_code=400, detail="Apenas links do YouTube são aceitos.")

    _sweep_stale_work_dirs()

    if not _download_slots.acquire(blocking=False):
        raise HTTPException(status_code=429, detail="Servidor ocupado com outros downloads. Tente em alguns segundos.")

    work_dir = tempfile.mkdtemp(prefix=WORK_DIR_PREFIX)
    started = time.monotonic()

    def cleanup() -> None:
        shutil.rmtree(work_dir, ignore_errors=True)

    try:
        audio_path, title = _extract_m4a(url, work_dir)
    except HTTPException:
        cleanup()
        raise
    except yt_dlp.utils.DownloadError as error:
        cleanup()
        # Mensagem completa só no log do servidor; o app recebe a versão amigável.
        log.warning("download falhou (%s): %s", url, str(error)[:600])
        raise HTTPException(status_code=422, detail=_friendly_error(str(error)))
    except Exception:
        cleanup()
        log.exception("erro inesperado no download (%s)", url)
        raise HTTPException(status_code=500, detail="Erro inesperado ao processar o áudio.")
    finally:
        # A vaga é liberada assim que a extração (parte pesada) termina;
        # o envio do arquivo em si é leve e não precisa segurar a vaga.
        _download_slots.release()

    log.info("download ok: %s · %.1f MB · %.1f s",
             audio_path.name, audio_path.stat().st_size / 1_048_576, time.monotonic() - started)

    # Auto-limpeza: roda só depois que o FileResponse terminou de enviar o arquivo.
    # Apaga a pasta inteira (inclui .part e restos do yt-dlp), não só o .m4a.
    background_tasks.add_task(cleanup)

    return FileResponse(
        path=audio_path,
        media_type="audio/mp4",           # MIME correto para .m4a (AAC em contêiner MP4)
        filename=f"{_safe_filename(title)}.m4a",
        headers={"Cache-Control": "no-store"},
        background=background_tasks,
    )


def _extract_m4a(url: str, work_dir: str) -> tuple[Path, str]:
    """Baixa só o áudio em .m4a para work_dir e devolve (caminho, título)."""
    has_ffmpeg = shutil.which("ffmpeg") is not None

    ydl_opts = {
        # Prefere o stream AAC/m4a nativo do YouTube: não precisa de conversão nem de FFmpeg.
        "format": "bestaudio[ext=m4a]/bestaudio" if has_ffmpeg else "bestaudio[ext=m4a]",
        "outtmpl": os.path.join(work_dir, "%(id)s.%(ext)s"),
        "noplaylist": True,          # link de música dentro de playlist → só a faixa
        "quiet": True,
        "no_warnings": True,
        "noprogress": True,
        "cachedir": False,           # nada persistido fora da pasta temporária
        "socket_timeout": 30,
        "retries": 3,
        "fragment_retries": 3,
    }
    if has_ffmpeg:
        # Se o melhor áudio disponível não for m4a, converte para m4a (AAC).
        ydl_opts["postprocessors"] = [{
            "key": "FFmpegExtractAudio",
            "preferredcodec": "m4a",
        }]

    cookie_copy = _prepare_cookies(work_dir)
    if cookie_copy:
        ydl_opts["cookiefile"] = cookie_copy

    with yt_dlp.YoutubeDL(ydl_opts) as ydl:
        info = ydl.extract_info(url, download=False)

        if info.get("is_live"):
            raise HTTPException(status_code=422, detail="Transmissões ao vivo não são suportadas.")
        duration = info.get("duration") or 0
        if duration > MAX_DURATION_SECONDS:
            raise HTTPException(
                status_code=413,
                detail=f"Áudio longo demais ({duration // 60} min). Limite: {MAX_DURATION_SECONDS // 60} min.",
            )

        ydl.process_ie_result(info, download=True)

    files = sorted(Path(work_dir).glob("*.m4a"))
    if not files:
        raise HTTPException(status_code=422, detail="Não foi possível obter o áudio em formato .m4a.")
    return files[0], info.get("title") or info.get("id") or "audio"


def _prepare_cookies(work_dir: str) -> str | None:
    """Copia o cookies.txt para a pasta do pedido.

    O yt-dlp regrava o arquivo de cookies ao terminar; o Secret File do Render é
    somente leitura, e pedidos simultâneos não devem disputar o mesmo arquivo.
    """
    if not COOKIES_FILE or not os.path.isfile(COOKIES_FILE):
        return None
    destination = os.path.join(work_dir, "cookies.txt")
    shutil.copyfile(COOKIES_FILE, destination)
    return destination


def _sweep_stale_work_dirs() -> None:
    """Apaga pastas de pedidos antigos que não foram limpas (ex.: o iPhone desconectou
    no meio do envio e a tarefa de limpeza não rodou)."""
    temp_root = Path(tempfile.gettempdir())
    cutoff = time.time() - STALE_AFTER_SECONDS
    for path in temp_root.glob(f"{WORK_DIR_PREFIX}*"):
        try:
            if path.is_dir() and path.stat().st_mtime < cutoff:
                shutil.rmtree(path, ignore_errors=True)
        except OSError:
            pass


def _friendly_error(message: str) -> str:
    lowered = message.lower()
    if "sign in to confirm your age" in lowered or ("age" in lowered and "restrict" in lowered):
        return "Vídeo com restrição de idade: não é possível extrair o áudio."
    if "private video" in lowered:
        return "Vídeo privado."
    if "confirm you're not a bot" in lowered or "confirm you’re not a bot" in lowered:
        return "O YouTube bloqueou o servidor temporariamente (verificação anti-bot)."
    if "video unavailable" in lowered or "not available" in lowered:
        return "Vídeo indisponível ou bloqueado na região do servidor."
    return "O yt-dlp não conseguiu processar este vídeo."


def _safe_filename(title: str) -> str:
    """Remove caracteres inválidos em nomes de arquivo e limita o tamanho."""
    cleaned = re.sub(r'[\\/:*?"<>|\r\n\t]+', " ", title)
    cleaned = re.sub(r"\s+", " ", cleaned).strip()
    return (cleaned or "audio")[:120]
