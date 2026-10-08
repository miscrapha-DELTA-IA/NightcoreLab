"""
Nightcore Lab — ponte de extração de áudio para o app iOS.

Nada fica guardado: cada pedido usa um diretório temporário próprio,
o .m4a é enviado direto na resposta e a pasta é apagada assim que o envio termina.

Rodar localmente:
    pip install -r requirements.txt
    uvicorn main:app --host 0.0.0.0 --port 8000

No Render (Start Command):
    uvicorn main:app --host 0.0.0.0 --port $PORT
"""

import os
import re
import shutil
import tempfile
from pathlib import Path
from urllib.parse import urlparse

import yt_dlp
from fastapi import BackgroundTasks, FastAPI, HTTPException
from fastapi.responses import FileResponse
from pydantic import BaseModel, HttpUrl

# Limite de duração para proteger CPU, disco e banda do tier gratuito (padrão: 20 min).
MAX_DURATION_SECONDS = int(os.getenv("MAX_DURATION_SECONDS", "1200"))

# Só aceita links do YouTube: impede que o servidor vire um proxy genérico de downloads.
ALLOWED_HOSTS = {
    "youtube.com",
    "www.youtube.com",
    "m.youtube.com",
    "music.youtube.com",
    "youtu.be",
}

app = FastAPI(
    title="Nightcore Lab Bridge",
    description="Extrai o áudio de um link do YouTube em .m4a e o envia direto, sem armazenar.",
    version="1.0.0",
)


class DownloadRequest(BaseModel):
    url: HttpUrl


@app.get("/")
def health():
    """Health check (também serve para 'acordar' o serviço no Render)."""
    return {"status": "ok", "ffmpeg": shutil.which("ffmpeg") is not None}


@app.post("/download")
def download(request: DownloadRequest, background_tasks: BackgroundTasks):
    # Função síncrona de propósito: o FastAPI a executa num thread pool,
    # então o yt-dlp (bloqueante) não trava o servidor para outros pedidos.
    url = str(request.url)
    host = (urlparse(url).hostname or "").lower()
    if host not in ALLOWED_HOSTS:
        raise HTTPException(status_code=400, detail="Apenas links do YouTube são aceitos.")

    work_dir = tempfile.mkdtemp(prefix="nightcore_")

    def cleanup() -> None:
        shutil.rmtree(work_dir, ignore_errors=True)

    try:
        audio_path, title = _extract_m4a(url, work_dir)
    except HTTPException:
        cleanup()
        raise
    except yt_dlp.utils.DownloadError as error:
        cleanup()
        raise HTTPException(status_code=422, detail=_friendly_error(str(error)))
    except Exception:
        cleanup()
        raise HTTPException(status_code=500, detail="Erro inesperado ao processar o áudio.")

    # Auto-limpeza: roda só depois que o FileResponse terminou de enviar o arquivo.
    # Apaga a pasta inteira (inclui .part e restos do yt-dlp), não só o .m4a.
    background_tasks.add_task(cleanup)

    return FileResponse(
        path=audio_path,
        media_type="audio/mp4",           # MIME correto para .m4a (AAC em contêiner MP4)
        filename=f"{_safe_filename(title)}.m4a",
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
    }
    if has_ffmpeg:
        # Se o melhor áudio disponível não for m4a, converte para m4a (AAC).
        ydl_opts["postprocessors"] = [{
            "key": "FFmpegExtractAudio",
            "preferredcodec": "m4a",
        }]

    with yt_dlp.YoutubeDL(ydl_opts) as ydl:
        info = ydl.extract_info(url, download=False)

        duration = info.get("duration") or 0
        if duration > MAX_DURATION_SECONDS:
            raise HTTPException(
                status_code=413,
                detail=f"Áudio longo demais ({duration // 60} min). Limite: {MAX_DURATION_SECONDS // 60} min.",
            )
        if info.get("is_live"):
            raise HTTPException(status_code=422, detail="Transmissões ao vivo não são suportadas.")

        ydl.process_ie_result(info, download=True)

    files = sorted(Path(work_dir).glob("*.m4a"))
    if not files:
        raise HTTPException(status_code=422, detail="Não foi possível obter o áudio em formato .m4a.")
    return files[0], info.get("title") or info.get("id") or "audio"


def _friendly_error(message: str) -> str:
    lowered = message.lower()
    if "sign in to confirm your age" in lowered or ("age" in lowered and "restrict" in lowered):
        return "Vídeo com restrição de idade: não é possível extrair o áudio."
    if "private video" in lowered:
        return "Vídeo privado."
    if "video unavailable" in lowered or "not available" in lowered:
        return "Vídeo indisponível ou bloqueado na região do servidor."
    if "confirm you're not a bot" in lowered or "confirm you’re not a bot" in lowered:
        return "O YouTube bloqueou o servidor temporariamente (verificação anti-bot)."
    return "O yt-dlp não conseguiu processar este vídeo."


def _safe_filename(title: str) -> str:
    """Remove caracteres inválidos em nomes de arquivo e limita o tamanho."""
    cleaned = re.sub(r'[\\/:*?"<>|\r\n\t]+', " ", title).strip()
    return (cleaned or "audio")[:120]
