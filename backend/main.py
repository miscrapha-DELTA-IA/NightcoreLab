"""
Nightcore Lab — ponte de extração de áudio para o app iOS.

Extrações concluídas podem ser reaproveitadas do cache LRU em /tmp (até 300 MB).
Diretórios de trabalho são descartados após o término dos envios.

Rodar localmente:
    pip install -r requirements.txt
    uvicorn main:app --host 0.0.0.0 --port 8000

No Render (Root Directory = backend):
    Build:  pip install -r requirements.txt
    Start:  uvicorn main:app --host 0.0.0.0 --port $PORT

YouTube exige um runtime de JavaScript desde o yt-dlp 2025.11.12: o requirements.txt
instala "yt-dlp[default]" (traz o yt-dlp-ejs) e o pacote "deno" (binário oficial do Deno).

Variáveis de ambiente opcionais:
    MAX_DURATION_SECONDS      limite fixo de segurança: duração inferior a 600 s (10 min)
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
import asyncio
import contextlib
from dataclasses import dataclass
import json
import logging
import os
import re
import shutil
import subprocess
import sys
import tempfile
import threading
import time
from pathlib import Path
from itertools import islice
from urllib.parse import parse_qs, urlparse

import yt_dlp
from fastapi import BackgroundTasks, FastAPI, HTTPException, Query
from fastapi.responses import FileResponse, Response
from pydantic import BaseModel, HttpUrl

MAX_DURATION_SECONDS = 600  # hard safety cap: strictly below ten minutes
MAX_CONCURRENT_DOWNLOADS = int(os.getenv("MAX_CONCURRENT_DOWNLOADS", "2"))
MAX_CACHE_BYTES = 300 * 1024 * 1024
CACHE_DIR = Path(os.getenv("AUDIO_CACHE_DIR", tempfile.gettempdir())) / "nightcore_audio_cache"
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

# Cache persists across requests in the same filesystem. /tmp is ephemeral on Render.
# Protect files being transmitted against LRU eviction.
_cache_lock = threading.RLock()
_cache_readers: dict[str, int] = {}


def _cached_audio(video_id: str) -> tuple[Path, str, str | None, str] | None:
    with _cache_lock:
        audio = CACHE_DIR / f"{video_id}.m4a"
        meta = CACHE_DIR / f"{video_id}.json"
        try:
            if not audio.is_file() or not meta.is_file():
                return None
            info = json.loads(meta.read_text(encoding="utf-8"))
            if audio.stat().st_size <= 0:
                return None
            os.utime(audio, None)  # atime/mtime tracks LRU reads.
            return audio, info["title"], info.get("thumbnail"), ""
        except (OSError, ValueError, KeyError, TypeError):
            return None


def _pin_cached_audio(video_id: str):
    with _cache_lock:
        result = _cached_audio(video_id)
        if result is not None:
            _cache_readers[video_id] = _cache_readers.get(video_id, 0) + 1
        return result


def _prune_audio_cache(protected: set[str] | None = None) -> None:
    with _cache_lock:
        if not CACHE_DIR.is_dir():
            return
        files = sorted(CACHE_DIR.glob("*.m4a"), key=lambda file: file.stat().st_mtime)
        total = sum(file.stat().st_size for file in files)
        for file in files:
            if total <= MAX_CACHE_BYTES:
                break
            video_id = file.stem
            if _cache_readers.get(video_id, 0) or (protected and video_id in protected):
                continue
            size = file.stat().st_size
            with contextlib.suppress(OSError):
                file.unlink()
                (CACHE_DIR / f"{video_id}.json").unlink(missing_ok=True)
                total -= size


def _cache_extracted_audio(video_id: str, result: tuple[Path, str, str | None, str]):
    audio, title, thumbnail, work_dir = result
    try:
        CACHE_DIR.mkdir(parents=True, exist_ok=True)
        with _cache_lock:
            target = CACHE_DIR / f"{video_id}.m4a"
            metadata = CACHE_DIR / f"{video_id}.json"
            # Atomic publish avoids serving a partially written file.
            staged = CACHE_DIR / f"{video_id}.{threading.get_ident()}.tmp"
            try:
                os.replace(audio, staged)  # same /tmp filesystem: no duplicate I/O
            except OSError:
                shutil.copyfile(audio, staged)
            os.replace(staged, target)
            staged_meta = CACHE_DIR / f"{video_id}.{threading.get_ident()}.json.tmp"
            staged_meta.write_text(json.dumps({"title": title, "thumbnail": thumbnail}), encoding="utf-8")
            os.replace(staged_meta, metadata)
            _prune_audio_cache(protected={video_id})
        return target, title, thumbnail, work_dir
    except OSError:
        log.exception("cache disk unavailable; returning temporary extraction")
        return result


download_semaphore = asyncio.Semaphore(min(MAX_CONCURRENT_DOWNLOADS, 2))

@dataclass
class InFlightDownload:
    task: asyncio.Task
    consumers: int = 0

in_flight_downloads: dict[str, InFlightDownload] = {}
_related_slots = threading.BoundedSemaphore(1)
_search_slots = threading.BoundedSemaphore(1)
RELATED_LIMIT = 10
RELATED_SCAN_LIMIT = 20

app = FastAPI(
    title="Nightcore Lab Bridge",
    description="Extrai o áudio de um link do YouTube em .m4a e o envia direto, sem armazenar.",
    version="1.4.0",
)


class DownloadRequest(BaseModel):
    url: HttpUrl


class RelatedVideo(BaseModel):
    title: str
    thumbnail: HttpUrl
    url: HttpUrl


def _youtube_video_id(url: str) -> str:
    """Valida o destino e normaliza watch, youtu.be, shorts, live e embed."""
    parsed = urlparse(url)
    host = (parsed.hostname or "").lower()
    if parsed.scheme not in {"http", "https"} or host not in ALLOWED_HOSTS:
        raise HTTPException(status_code=400, detail="Apenas links do YouTube são aceitos.")
    if parsed.username or parsed.password or parsed.port not in {None, 80, 443}:
        raise HTTPException(status_code=400, detail="Link do YouTube inválido.")
    parts = parsed.path.strip("/").split("/")
    video_id = ""
    if host == "youtu.be" and len(parts) == 1:
        video_id = parts[0]
    elif parsed.path.rstrip("/") == "/watch":
        video_id = parse_qs(parsed.query).get("v", [""])[0]
    elif len(parts) == 2 and parts[0] in {"shorts", "live", "embed"}:
        video_id = parts[1]
    if not re.fullmatch(r"[A-Za-z0-9_-]{11}", video_id):
        raise HTTPException(status_code=400, detail="Use o link de um vídeo do YouTube.")
    return video_id


def _related_entries(info: dict, seed_id: str) -> list[RelatedVideo]:
    seen = {seed_id}
    videos = []
    for entry in islice(info.get("entries") or [], RELATED_SCAN_LIMIT):
        if not isinstance(entry, dict):
            continue
        video_id = entry.get("id")
        title = entry.get("title")
        if not isinstance(video_id, str) or not re.fullmatch(r"[A-Za-z0-9_-]{11}", video_id):
            continue
        if video_id in seen or not isinstance(title, str) or not title.strip():
            continue
        if entry.get("is_live") or entry.get("availability") in {"private", "premium_only", "subscriber_only"}:
            continue
        duration = entry.get("duration")
        if isinstance(duration, (int, float)) and duration >= MAX_DURATION_SECONDS:
            continue
        seen.add(video_id)
        thumbnails = [entry.get("thumbnail")]
        thumbnails.extend(t.get("url") for t in reversed(entry.get("thumbnails") or []) if isinstance(t, dict))
        thumbnail = next((t for t in thumbnails if isinstance(t, str) and t.startswith("https://")),
                         f"https://i.ytimg.com/vi/{video_id}/hqdefault.jpg")
        videos.append(RelatedVideo(title=title.strip(), thumbnail=thumbnail,
                                   url=f"https://www.youtube.com/watch?v={video_id}"))
        if len(videos) == RELATED_LIMIT:
            break
    return videos


@app.get("/related", response_model=list[RelatedVideo])
def related(url: HttpUrl):
    """Sugestões do Mix público do YouTube, sem baixar áudio ou extrair cada vídeo."""
    video_id = _youtube_video_id(str(url))
    if not _related_slots.acquire(blocking=False):
        raise HTTPException(status_code=429, detail="Sugestões ocupadas. Tente novamente.")
    try:
        options = {
            "extract_flat": True,
            "skip_download": True,
            "match_filter": yt_dlp.utils.match_filter_func("duration < 600"),
            "noplaylist": False,
            "playlistend": RELATED_SCAN_LIMIT,
            "lazy_playlist": True,
            "quiet": True,
            "logger": _YtdlpLog("related"),
            "cachedir": False,
            "socket_timeout": 8,
            "retries": 0,
            "extractor_retries": 0,
        }
        # A consulta usa o Mix público, não as recomendações pessoais dos cookies.
        mix_url = f"https://www.youtube.com/watch?v={video_id}&list=RD{video_id}"
        with yt_dlp.YoutubeDL(options) as ydl:
            info = ydl.extract_info(mix_url, download=False)
            if not isinstance(info, dict):
                return []
            return _related_entries(info, video_id)
    except yt_dlp.utils.DownloadError:
        log.warning("Mix indisponível para %s", video_id)
        raise HTTPException(status_code=502, detail="Sugestões temporariamente indisponíveis.")
    except Exception:
        log.exception("Erro ao consultar sugestões para %s", video_id)
        raise HTTPException(status_code=503, detail="Sugestões temporariamente indisponíveis.")
    finally:
        _related_slots.release()


def _music_search_entries(items: list[dict]) -> str:
    """Return the existing Swift-compatible NDJSON contract using YT Music songs."""
    accepted = []
    seen = set()
    for item in items:
        if not isinstance(item, dict) or item.get("resultType") != "song":
            continue
        video_id = item.get("videoId")
        duration = item.get("duration_seconds")
        if (not isinstance(video_id, str) or not re.fullmatch(r"[A-Za-z0-9_-]{11}", video_id)
                or not isinstance(duration, (int, float))
                or not 0 < duration < MAX_DURATION_SECONDS
                or item.get("isAvailable") is False or video_id in seen):
            continue
        title = item.get("title")
        if not isinstance(title, str) or not title.strip():
            continue
        seen.add(video_id)
        artwork = next((thumb.get("url") for thumb in reversed(item.get("thumbnails") or [])
                        if isinstance(thumb, dict) and isinstance(thumb.get("url"), str)
                        and thumb["url"].startswith("https://")), None)
        accepted.append(json.dumps({"id": video_id, "title": title.strip(),
                                    "duration": duration, "thumbnail": artwork,
                                    "is_live": False}, ensure_ascii=False))
        if len(accepted) >= 15:
            break
    return "\n".join(accepted) + ("\n" if accepted else "")


@app.get("/search")
def search(query: str = Query(min_length=1, max_length=200)):
    """Search YouTube Music songs without invoking yt-dlp or extracting audio."""
    query = query.strip()
    if not query:
        raise HTTPException(status_code=400, detail="Digite uma busca.")
    if not _search_slots.acquire(blocking=False):
        raise HTTPException(status_code=429, detail="Busca ocupada. Tente novamente.")
    try:
        from ytmusicapi import YTMusic
        results = YTMusic().search(query, filter="songs", limit=20)
        return Response(content=_music_search_entries(results),
                        media_type="application/x-ndjson",
                        headers={"Cache-Control": "no-store"})
    except Exception:
        log.exception("YouTube Music search failed")
        raise HTTPException(status_code=502, detail="Busca musical temporariamente indisponível.")
    finally:
        _search_slots.release()


@app.get("/download")
async def background_download(url: HttpUrl, background_tasks: BackgroundTasks):
    """Background URLSession compatible GET, sharing the POST extraction."""
    _youtube_video_id(str(url))
    return await download(DownloadRequest(url=url), background_tasks)


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


def _run_extraction(url: str) -> tuple[Path, str, str | None, str]:
    """Blocking yt-dlp work runs in a worker thread, never on the event loop."""
    _sweep_stale_work_dirs()  # Runs in asyncio.to_thread, not on the event loop.
    work_dir = tempfile.mkdtemp(prefix=WORK_DIR_PREFIX)
    try:
        audio_path, title, thumbnail = _extract_m4a(url, work_dir)
        return audio_path, title, thumbnail, work_dir
    except BaseException:
        shutil.rmtree(work_dir, ignore_errors=True)
        raise


async def _shared_extraction(url: str):
    # The semaphore is always released by the context manager, including on failure.
    # Do not cancel to_thread on client disconnect: the blocking worker cannot be killed.
    async with download_semaphore:
        try:
            result = await asyncio.to_thread(_run_extraction, url)
            return await asyncio.to_thread(_cache_extracted_audio, _youtube_video_id(url), result)
        finally:
            log.debug("yt-dlp worker finished or cancelled for %s", url)


async def _cleanup_orphan(video_id: str, entry: InFlightDownload) -> None:
    # A client can disconnect before extraction finishes. Clean up once the
    # worker returns, even when no FileResponse was ever created.
    if entry.consumers == 0:
        await _release_download(video_id, entry, decrement=False)


async def _release_download(video_id: str, entry: InFlightDownload,
                            decrement: bool = True) -> None:
    if decrement:
        entry.consumers -= 1
    if entry.consumers == 0 and entry.task.done():
        if in_flight_downloads.get(video_id) is entry:
            in_flight_downloads.pop(video_id, None)
        try:
            if not entry.task.cancelled() and entry.task.exception() is None:
                workspace = entry.task.result()[3]
                if workspace:
                    await asyncio.to_thread(shutil.rmtree, workspace, ignore_errors=True)
        except Exception:
            log.exception("failed to clean download workspace for %s", video_id)


async def _release_response(video_id: str, entry: InFlightDownload) -> None:
    # Starlette runs async background callbacks on the owning event loop.
    await _release_download(video_id, entry)


@app.post("/download")
async def download(request: DownloadRequest, background_tasks: BackgroundTasks):
    url = str(request.url)
    video_id = _youtube_video_id(url)
    entry = in_flight_downloads.get(video_id)
    if entry is None:
        # Pin the cache entry atomically with lookup: pruning runs under the same lock.
        hit = await asyncio.to_thread(_pin_cached_audio, video_id)
        entry = in_flight_downloads.get(video_id)
        if entry is None and hit is not None:
            audio_path, title, thumbnail, _ = hit
            background_tasks.add_task(_release_cached_reader, video_id)
            return _audio_response(audio_path, title, thumbnail, background_tasks)
        if hit is not None:
            _release_cached_reader(video_id)
    if entry is None:
        entry = InFlightDownload(task=asyncio.create_task(_shared_extraction(url)))
        in_flight_downloads[video_id] = entry
        entry.task.add_done_callback(lambda _, vid=video_id, item=entry: asyncio.create_task(_cleanup_orphan(vid, item)))
    entry.consumers += 1
    try:
        # A disconnected consumer must not cancel the extraction for other clients.
        audio_path, title, thumbnail, _ = await asyncio.wait_for(
            asyncio.shield(entry.task), timeout=240
        )
    except asyncio.TimeoutError:
        await _release_download(video_id, entry)
        raise HTTPException(status_code=504, detail="Tempo limite de extração excedido.")
    except yt_dlp.utils.DownloadError as error:
        await _release_download(video_id, entry)
        log.warning("download falhou (%s): %s", video_id, str(error)[:600])
        raise HTTPException(status_code=422, detail=_friendly_error(str(error)))
    except HTTPException:
        await _release_download(video_id, entry)
        raise
    except asyncio.CancelledError:
        # Keep the shared extraction alive; its cleanup callback handles orphaned tasks.
        await _release_download(video_id, entry)
        raise
    except Exception:
        await _release_download(video_id, entry)
        log.exception("falha ao processar áudio %s", video_id)
        raise HTTPException(status_code=500, detail="Erro inesperado ao processar o áudio.")

    # Retain the file until this response has finished transmitting. Multiple
    # consumers share the same task but own independent response lifetimes.
    background_tasks.add_task(_release_response, video_id, entry)
    if audio_path.parent == CACHE_DIR:
        with _cache_lock:
            _cache_readers[video_id] = _cache_readers.get(video_id, 0) + 1
        background_tasks.add_task(_release_cached_reader, video_id)
    return _audio_response(audio_path, title, thumbnail, background_tasks)


def _release_cached_reader(video_id: str) -> None:
    with _cache_lock:
        count = _cache_readers.get(video_id, 0) - 1
        if count <= 0:
            _cache_readers.pop(video_id, None)
        else:
            _cache_readers[video_id] = count


def _audio_response(audio_path: Path, title: str, thumbnail: str | None,
                    background_tasks: BackgroundTasks) -> FileResponse:
    headers = {"Cache-Control": "no-store"}
    if thumbnail:
        headers["X-Cover-Url"] = thumbnail
    return FileResponse(
        path=audio_path, media_type="audio/mp4",
        filename=f"{_safe_filename(title)}.m4a",
        headers=headers, background=background_tasks,
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
        "match_filter": yt_dlp.utils.match_filter_func("duration < 600"),
        "quiet": True,
        "no_warnings": False,
        "logger": _YtdlpLog(label),
        "noprogress": True,
        "cachedir": False,           # nada persistido fora da pasta temporária
        "socket_timeout": 30,
        "retries": 3,
        "fragment_retries": 3,
        "concurrent_fragment_downloads": 4,  # only segmented DASH/HLS; no effect on single-file m4a
    }
    if clients:
        ydl_opts["extractor_args"] = {"youtube": {"player_client": clients}}
    if has_ffmpeg:
        # Se o melhor áudio disponível não for m4a, converte para m4a (AAC).
        ydl_opts["postprocessors"] = [{
            "key": "FFmpegExtractAudio",
            "preferredcodec": "m4a",
            "preferredquality": "320",  # kb/s quando houver conversão; AAC/m4a nativo é preservado
        }]
    if use_cookies:
        ydl_opts["cookiefile"] = _prepare_cookies(work_dir)

    with yt_dlp.YoutubeDL(ydl_opts) as ydl:
        info = ydl.extract_info(url, download=False)

        if info.get("is_live"):
            raise HTTPException(status_code=422, detail="Transmissões ao vivo não são suportadas.")
        duration = info.get("duration")
        if not isinstance(duration, (int, float)) or duration >= MAX_DURATION_SECONDS:
            raise HTTPException(
                status_code=413,
                detail="Duração desconhecida ou faixa de 10 minutos ou mais. Download bloqueado.",
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
        if path == CACHE_DIR or path.name == CACHE_DIR.name:
            continue
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


