"""Conservative independent audio recovery inside the existing extraction worker.

Only server-observed catalog metadata can associate a YouTube identity with a
public Audius recording. No client-supplied URL, preview, login or gated stream.
The player contract remains one complete, validated M4A file.
"""
from dataclasses import dataclass
import json
import logging
import math
from pathlib import Path
import re
import shutil
import subprocess
import threading
import time
import unicodedata
from urllib.parse import urljoin, urlparse

from cachetools import TTLCache
import requests

log = logging.getLogger("uvicorn.error")
API = "https://api.audius.co/v1"
# Exact storage origin observed behind the official Audius creator node.
# Do not allow arbitrary cloud-storage tenants or provider-supplied hosts.
STORAGE_HOST = "validator.eeba4a6ca56a0d87af802270217c2a51.r2.cloudflarestorage.com"
MAX_BYTES = 32 * 1024 * 1024
_lock = threading.RLock()
_metadata = TTLCache(maxsize=2048, ttl=86400)
_misses = TTLCache(maxsize=2048, ttl=300)
_provider_retry_at = 0.0


@dataclass(frozen=True)
class Recording:
    title: str
    artist: str
    duration: float
    thumbnail: str | None = None


def remember(video_id, title, artist, duration, thumbnail=None):
    """Called only by parsed catalog responses, never by arbitrary request hints."""
    if (not isinstance(video_id, str) or not re.fullmatch(r"[A-Za-z0-9_-]{11}", video_id)
            or not isinstance(title, str) or not title.strip()
            or not isinstance(artist, str) or not artist.strip()
            or isinstance(duration, bool) or not isinstance(duration, (int, float))
            or not math.isfinite(duration) or not 0 < duration < 600):
        return
    recording = Recording(title[:300], artist[:300], float(duration), thumbnail)
    with _lock:
        if _metadata.get(video_id) != recording:
            _misses.pop(video_id, None)
        _metadata[video_id] = recording


def can_recover(video_id):
    with _lock:
        return (video_id in _metadata and video_id not in _misses
                and time.monotonic() >= _provider_retry_at)


def _key(text):
    text = unicodedata.normalize("NFKD", str(text)).casefold()
    return " ".join("".join(c if c.isalnum() else " " for c in text
                            if not unicodedata.combining(c)).split())


def _title(text, artist):
    # Remove only presentation noise, not remix/live/remaster/version markers.
    text = re.sub(r"(?i)\s*[\[(]official\s+(?:audio|music video|video)[\])]", "", text)
    value, prefix = _key(text), _key(artist) + " "
    return value[len(prefix):] if value.startswith(prefix) else value


def matches(recording, track):
    if not isinstance(track, dict):
        return False
    user = track.get("user") or {}
    duration = track.get("duration")
    title = track.get("title")
    access = track.get("access") or {}
    return (isinstance(user, dict) and user.get("is_verified") is True
            and isinstance(title, str) and isinstance(access, dict)
            and track.get("is_streamable") is True
            and track.get("is_available", True) is True
            and not track.get("is_stream_gated") and not track.get("stream_conditions")
            and not track.get("is_delete") and not track.get("is_unlisted")
            and access.get("stream", True) is True
            and isinstance(duration, (int, float)) and not isinstance(duration, bool)
            and math.isfinite(duration) and 0 < duration < 600
            and abs(duration - recording.duration) <= 2
            and _key(user.get("name", "")) == _key(recording.artist)
            and _title(title, recording.artist) == _title(recording.title, recording.artist)
            and isinstance(track.get("id"), str)
            and re.fullmatch(r"[A-Za-z0-9]+", track["id"]) is not None)


def _allowed_url(url):
    parts = urlparse(url)
    host = (parts.hostname or "").lower()
    return (parts.scheme == "https" and not parts.username and not parts.password
            and parts.port in (None, 443)
            and (host == "audius.co" or host.endswith(".audius.co")
                 or host == "audius.org" or host.endswith(".audius.org")
                 or host == STORAGE_HOST))


def _get(session, url, deadline, params=None):
    """Bound redirects to Audius infrastructure. Never send auth or follow arbitrary hosts."""
    global _provider_retry_at
    for _ in range(4):
        if not _allowed_url(url) or time.monotonic() >= deadline:
            raise ValueError("invalid source or deadline")
        response = session.get(url, params=params, stream=True, allow_redirects=False,
                               timeout=(8, min(12, max(1, deadline - time.monotonic()))))
        if response.status_code in (429, 500, 502, 503, 504):
            with _lock:
                _provider_retry_at = time.monotonic() + (300 if response.status_code == 429 else 30)
        if response.status_code in (301, 302, 303, 307, 308):
            url = urljoin(response.url, response.headers.get("Location", ""))
            params = None
            response.close()
            continue
        if response.status_code != 200:
            response.close()
            raise ValueError("source unavailable")
        return response
    raise ValueError("redirect limit")


def _chunks(response, limit, deadline):
    total = 0
    for chunk in response.iter_content(64 * 1024):
        total += len(chunk)
        if total > limit or time.monotonic() >= deadline:
            raise ValueError("source exceeds budget")
        yield chunk


def _convert(source, destination, duration):
    # Local input only: ffmpeg cannot fetch protocols from a playlist disguised as audio.
    probe = subprocess.run(["ffprobe", "-v", "error", "-protocol_whitelist", "file,pipe",
        "-show_entries", "format=duration:stream=codec_name,codec_type", "-of", "json", str(source)],
        capture_output=True, timeout=8, check=True)
    details = json.loads(probe.stdout)
    actual = float(details["format"]["duration"])
    if not math.isfinite(actual) or abs(actual - duration) > 2 or not 0 < actual < 600:
        raise ValueError("preview, truncated or different recording")
    codec = next((stream.get("codec_name") for stream in details.get("streams", [])
                  if stream.get("codec_type") == "audio"), None)
    codec_args = ["-c:a", "copy"] if codec == "aac" else ["-c:a", "aac", "-b:a", "192k"]
    subprocess.run(["ffmpeg", "-nostdin", "-v", "error", "-protocol_whitelist", "file,pipe",
        "-i", str(source), "-map", "0:a:0", "-vn", *codec_args,
        "-threads", "1", "-movflags", "+faststart", "-y", str(destination)],
        capture_output=True, timeout=60, check=True)
    if destination.stat().st_size < 1024:
        raise ValueError("empty audio")


def recover(video_id, work_dir):
    """Return the existing (path, title, cover) tuple or None; never mask the original error."""
    if not can_recover(video_id) or not shutil.which("ffmpeg") or not shutil.which("ffprobe"):
        return None
    with _lock:
        recording = _metadata.get(video_id)
    if recording is None:
        return None
    source = Path(work_dir) / "alternative.audio"
    output = Path(work_dir) / "alternative.m4a"
    try:
        deadline = time.monotonic() + 35
        with requests.Session() as session:
            with _get(session, API + "/tracks/search", deadline, params={
                "query": recording.artist + " " + recording.title, "limit": 8,
                "app_name": "Gnarly", "include_purchaseable": "false"}) as response:
                payload = json.loads(b"".join(_chunks(response, 2 * 1024 * 1024, deadline)))
            candidates = [track for track in payload.get("data", []) if matches(recording, track)]
            # Ambiguous versions are not interchangeable, even if metadata looks similar.
            unique = {track["id"]: track for track in candidates}
            if len(unique) != 1:
                raise ValueError("no unambiguous recording")
            track = next(iter(unique.values()))
            with _get(session, API + "/tracks/" + track["id"] + "/stream", deadline,
                      params={"app_name": "Gnarly"}) as response:
                if response.headers.get("Content-Type", "").split(";")[0] not in (
                    "audio/mpeg", "audio/mp3", "audio/mp4", "audio/aac", "audio/flac",
                    "application/octet-stream"):
                    raise ValueError("not full audio")
                with source.open("wb") as target:
                    for chunk in _chunks(response, MAX_BYTES, deadline):
                        target.write(chunk)
            _convert(source, output, recording.duration)
        log.info("audio recovery source=audius video=%s", video_id)
        return output, recording.title, recording.thumbnail
    except Exception as error:
        # Never log signed media URLs, headers, response bodies or credentials.
        log.info("audio recovery unavailable video=%s reason=%s", video_id, type(error).__name__)
        with _lock:
            _misses[video_id] = True
        output.unlink(missing_ok=True)
        return None
    finally:
        source.unlink(missing_ok=True)
