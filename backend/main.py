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
                              /etc/secrets/<nome do Secret File>. O nome precisa bater
                              exatamente (em produção: /etc/secrets/COOKIES_FILE).
                              Diagnóstico: o health check (GET /) mostra "cookies",
                              "cookies_env" e "secret_files".
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
    version="1.3.0",
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
        # Diagnóstico (só nomes, nunca o conteúdo): ajuda a achar o que falta na configuração.
        "cookies_env": COOKIES_FILE or None,
        "cookies_summary": _cookies_summary(),
        "secret_files": _secret_file_names(),
    }


# Cookies que só existem numa sessão logada do Google/YouTube.
_LOGIN_COOKIE_NAMES = {"LOGIN_INFO", "SAPISID", "__Secure-3PAPISID", "__Secure-3PSID", "SID", "HSID", "SSID"}


def _cookies_summary() -> dict:
    """Resume o cookies.txt sem expor valores: formato, quantidade e se há sessão logada."""
    if not COOKIES_FILE or not os.path.isfile(COOKIES_FILE):
        return {"found": False}
    try:
        with open(COOKIES_FILE, encoding="utf-8", errors="replace") as handle:
            lines = handle.read().splitlines()
    except OSError:
        return {"found": True, "readable": False}

    header_ok = bool(lines) and "HTTP Cookie File" in lines[0]
    names, domains = set(), set()
    for line in lines:
        if line.startswith("#HttpOnly_"):
            line = line[len("#HttpOnly_"):]
        elif not line.strip() or line.startswith("#"):
            continue
        parts = line.split("\t")
        if len(parts) >= 7:
            domains.add(parts[0].lstrip("."))
            names.add(parts[5])
    login = sorted(names & _LOGIN_COOKIE_NAMES)
    return {
        "found": True,
        "netscape_header": header_ok,
        "entries": len(names),
        "youtube_domain": any(d.endswith("youtube.com") for d in domains),
        "login_cookies": login,          # só nomes, nunca valores
        "logged_in": "LOGIN_INFO" in login or "SAPISID" in login,
    }


def _secret_file_names() -> list[str]:
    """Nomes dos Secret Files do Render (pasta /etc/secrets), sem ler o conteúdo."""
    try:
        return sorted(os.listdir("/etc/secrets"))
    except OSError:
        return []


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
        audio_path, title, thumbnail = _extract_m4a(url, work_dir)
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

    headers = {"Cache-Control": "no-store"}
    if thumbnail:
        headers["X-Cover-Url"] = thumbnail

    return FileResponse(
        path=audio_path,
        media_type="audio/mp4",           # MIME correto para .m4a (AAC em contêiner MP4)
        filename=f"{_safe_filename(title)}.m4a",
        headers=headers,
        background=background_tasks,
    )


class _YtdlpLog:
    """Leva os avisos do yt-dlp para o log do Render (é neles que o YouTube explica
    por que um formato sumiu: PO token, desafio JS, cookies vencidos...)."""

    def __init__(self, label: str) -> None:
        self.label = label

    def debug(self, msg: str) -> None:   # progresso e mensagens informativas: silencia
        pass

    def info(self, msg: str) -> None:
        pass

    def warning(self, msg: str) -> None:
        log.warning("yt-dlp [%s]: %s", self.label, msg[:500])

    def error(self, msg: str) -> None:   # o erro final já é registrado em download()
        pass


# Estratégias tentadas em ordem até uma entregar áudio. O YouTube muda com frequência
# quais clientes exigem PO token num IP de datacenter; ter alternativas evita o app quebrar.
#   (rótulo, usa cookies?, clientes do player — None = padrão do yt-dlp)
_STRATEGIES: list[tuple[str, bool, list[str] | None]] = [
    ("logado/padrão", True, None),                          # web_embedded, tv_downgraded, web
    ("logado/tv", True, ["tv", "web_embedded", "mweb"]),    # tv e web_embedded dispensam PO token
    ("anônimo/visionos", False, ["visionos", "android_vr"]),
    ("anônimo/padrão", False, None),
]

# Erros em que vale tentar a próxima estratégia (os demais são definitivos: vídeo privado etc.).
_RETRYABLE = (
    "requested format is not available",
    "not a bot",
    "only images are available",
    "no video formats found",
    "po token",
    "http error 403",
    "this content isn't available",
)


def _extract_m4a(url: str, work_dir: str) -> tuple[Path, str, str | None]:
    """Baixa só o áudio em .m4a para work_dir e devolve (caminho, título, URL da capa)."""
    has_cookies = bool(COOKIES_FILE) and os.path.isfile(COOKIES_FILE)
    if has_cookies:
        summary = _cookies_summary()
        log.info("cookies: %s entradas, youtube=%s, logado=%s (%s)",
                 summary.get("entries"), summary.get("youtube_domain"),
                 summary.get("logged_in"), ", ".join(summary.get("login_cookies", [])) or "nenhum")
    else:
        log.info("sem cookies (COOKIES_FILE=%r)", COOKIES_FILE)

    strategies = [s for s in _STRATEGIES if has_cookies or not s[1]]
    last_error: yt_dlp.utils.DownloadError | None = None

    for index, (label, use_cookies, clients) in enumerate(strategies):
        attempt_dir = os.path.join(work_dir, f"try{index}")
        os.makedirs(attempt_dir)
        try:
            result = _extract_with(url, attempt_dir, label, use_cookies, clients)
            log.info("estratégia que funcionou: %s", label)
            return result
        except yt_dlp.utils.DownloadError as error:
            last_error = error
            message = str(error)
            log.warning("estratégia %s falhou: %s", label, message[:300])
            if not any(marker in message.lower() for marker in _RETRYABLE):
                raise

    assert last_error is not None
    raise last_error


def _extract_with(url: str, work_dir: str, label: str,
                  use_cookies: bool, clients: list[str] | None) -> tuple[Path, str, str | None]:
    has_ffmpeg = shutil.which("ffmpeg") is not None

    ydl_opts = {
        # 1º o AAC/m4a nativo (sem conversão); depois qualquer áudio; por fim qualquer
        # stream com som (o FFmpeg extrai e converte o áudio para m4a).
        "format": "bestaudio[ext=m4a]/bestaudio/best[acodec!=none]" if has_ffmpeg else "bestaudio[ext=m4a]",
        "outtmpl": os.path.join(work_dir, "%(id)s.%(ext)s"),
        "noplaylist": True,          # link de música dentro de playlist → só a faixa
        "quiet": True,
        "no_warnings": False,
        "logger": _YtdlpLog(label),
        "noprogress": True,
        "cachedir": False,           # nada persistido fora da pasta temporária
        "socket_timeout": 30,
        "retries": 3,
        "fragment_retries": 3,
    }
    if clients:
        ydl_opts["extractor_args"] = {"youtube": {"player_client": clients}}
    if has_ffmpeg:
        # Se o melhor áudio disponível não for m4a, converte para m4a (AAC).
        ydl_opts["postprocessors"] = [{
            "key": "FFmpegExtractAudio",
            "preferredcodec": "m4a",
        }]
    if use_cookies:
        ydl_opts["cookiefile"] = _prepare_cookies(work_dir)

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
    thumbnail = info.get("thumbnail")
    return files[0], info.get("title") or info.get("id") or "audio", thumbnail


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
    if "requested format is not available" in lowered or "only images are available" in lowered:
        return "O YouTube não liberou o áudio deste vídeo para o servidor. Tente de novo em alguns minutos."
    if "unavailable" in lowered or "not available" in lowered:
        return "Vídeo indisponível ou bloqueado na região do servidor."
    return "O yt-dlp não conseguiu processar este vídeo."


def _safe_filename(title: str) -> str:
    """Remove caracteres inválidos em nomes de arquivo e limita o tamanho."""
    cleaned = re.sub(r'[\\/:*?"<>|\r\n\t]+', " ", title)
    cleaned = re.sub(r"\s+", " ", cleaned).strip()
    return (cleaned or "audio")[:120]
