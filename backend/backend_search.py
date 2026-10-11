"""
Rota de busca do Nightcore Lab (FastAPI/Render).

Por que YT Music `filter="songs"` em vez de busca comum do YouTube:
  - devolve artista, álbum e duração JÁ estruturados (nada de "(Official Video)" no título);
  - ignora vídeos de reação, covers e letras de terceiros na maior parte dos casos;
  - o app só precisa do videoId para o yt-dlp extrair a URL (sem passar pela busca lenta do yt-dlp).

AVISO: ytmusicapi é um cliente NÃO oficial (emula as requisições do site). Mesma "zona cinza"
do yt-dlp: pode quebrar sem aviso. Mantenha a versão fixada e tenha o fallback do app.
NÃO testado contra o YouTube neste ambiente.
"""
import logging
import threading

from cachetools import TTLCache
from fastapi import APIRouter, HTTPException, Query
from ytmusicapi import YTMusic

router = APIRouter()
log = logging.getLogger(__name__)
_guard = threading.BoundedSemaphore(2)
_cache_lock = threading.RLock()
# Instanciar YTMusic sob demanda evita IO/rede durante a importação do backend.
_search_cache: TTLCache = TTLCache(maxsize=2048, ttl=600)
_suggest_cache: TTLCache = TTLCache(maxsize=2048, ttl=300)


def _hit(r: dict, is_song: bool) -> dict:
    artists = ", ".join(a["name"] for a in (r.get("artists") or []) if a.get("name"))
    thumbs = r.get("thumbnails") or []
    return {
        "id": r["videoId"],
        "title": r.get("title", ""),
        "artist": artists,
        "album": r.get("album", {}).get("name") if isinstance(r.get("album"), dict) else None,
        "duration": r.get("duration_seconds") if isinstance(r.get("duration_seconds"), (int, float)) else None,
        "thumb": thumbs[-1]["url"] if thumbs else None,
        "isSong": is_song,
        "explicit": bool(r.get("isExplicit", False)),
    }


@router.get("/v1/search")
def search(q: str = Query(..., min_length=2, max_length=120), limit: int = Query(10, ge=1, le=20)):
    key = (q.strip().lower(), limit)
    if not key[0]:
        raise HTTPException(status_code=422, detail="Consulta vazia.")
    with _cache_lock:
        if key in _search_cache:
            return _search_cache[key]
    if not _guard.acquire(blocking=False):
        raise HTTPException(status_code=429, detail="Busca ocupada. Tente novamente.")
    try:
        ytm = YTMusic()
        out = [_hit(r, True) for r in ytm.search(q, filter="songs", limit=limit)
               if r.get("videoId")]
        if len(out) < 3:
            seen = {h["id"] for h in out}
            for r in ytm.search(q, filter="videos", limit=limit):
                if r.get("videoId") and r["videoId"] not in seen:
                    out.append(_hit(r, False))
                    seen.add(r["videoId"])
        out = out[:limit]
        with _cache_lock:
            _search_cache[key] = out
        return out
    except Exception as exc:
        log.warning("YT Music v1 search failed: %s", type(exc).__name__)
        raise HTTPException(status_code=502, detail="Busca musical temporariamente indisponível.") from exc
    finally:
        _guard.release()


@router.get("/v1/suggest", response_model=list[str])
def suggest(q: str = Query(..., min_length=1, max_length=80)) -> list[str]:
    key = q.strip().lower()
    if not key:
        return []
    with _cache_lock:
        if key in _suggest_cache:
            return _suggest_cache[key]
    if not _guard.acquire(blocking=False):
        raise HTTPException(status_code=429, detail="Busca ocupada.")
    try:
        suggestions = [v for v in YTMusic().get_search_suggestions(q) if isinstance(v, str)][:6]
        with _cache_lock:
            _suggest_cache[key] = suggestions
        return suggestions
    except Exception as exc:
        log.warning("YT Music suggestions failed: %s", type(exc).__name__)
        raise HTTPException(status_code=502, detail="Sugestões indisponíveis.") from exc
    finally:
        _guard.release()
