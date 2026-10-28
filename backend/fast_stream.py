"""Optional AAC progressive streaming without waiting for a complete yt-dlp download.

Only formats disclosed by the validated video identity are accepted. The source
must be direct HTTPS audio/mp4 from a Google video host. Unsupported codecs,
HLS/DASH fragments, redirects, private/region-restricted content and failures
fall back to the existing /download extraction route at the Pages edge.
Never leak signed media URLs, cookies or upstream tokens in logs or headers.
"""
from __future__ import annotations
from dataclasses import dataclass
from urllib.parse import urlsplit
import math
import re

MAX_AUDIO_BYTES = 72 * 1024 * 1024
RANGE_PATTERN = re.compile(r"bytes=(?:[0-9]+-[0-9]*|-[0-9]+)\Z")
OUTPUT_HEADERS = ("content-length", "content-range", "accept-ranges", "etag")

@dataclass(frozen=True)
class ProgressiveSource:
    url: str
    duration: float
    format_id: str

def valid_google_audio_url(raw: object) -> bool:
    if not isinstance(raw, str) or len(raw) > 6000:
        return False
    try:
        value = urlsplit(raw)
        host = (value.hostname or "").lower()
        return (value.scheme == "https" and value.username is None and
                value.password is None and value.port in (None, 443) and
                (host == "googlevideo.com" or host.endswith(".googlevideo.com")) and
                bool(value.path) and not value.fragment)
    except ValueError:
        return False

def choose_progressive_source(info: dict) -> ProgressiveSource | None:
    if not isinstance(info, dict) or info.get("is_live"):
        return None
    duration = info.get("duration")
    if (not isinstance(duration, (int, float)) or isinstance(duration, bool) or
            not math.isfinite(duration) or duration <= 0 or duration >= 600):
        return None
    candidates = info.get("formats") or [info]
    acceptable = []
    for item in candidates:
        if not isinstance(item, dict):
            continue
        acodec = item.get("acodec") or ""
        protocol = (item.get("protocol") or "").lower()
        if (item.get("ext") != "m4a" or not str(acodec).startswith("mp4a") or
                item.get("vcodec") not in ("none", None) or
                protocol not in ("https", "http", "") or
                item.get("fragments") or item.get("manifest_url") or
                not valid_google_audio_url(item.get("url"))):
            continue
        size = item.get("filesize") or item.get("filesize_approx") or 0
        if size and (not isinstance(size, (int, float)) or size > MAX_AUDIO_BYTES):
            continue
        # Prefer a music-compatible moderate AAC bitrate to lower time to play.
        bitrate = float(item.get("abr") or item.get("tbr") or 128)
        acceptable.append((abs(bitrate-128),item))
    if not acceptable:
        return None
    best = min(acceptable,key=lambda entry:entry[0])[1]
    return ProgressiveSource(url=best["url"],duration=float(duration),
                             format_id=str(best.get("format_id") or "")[:24])

def forwarded_audio_headers(upstream) -> dict[str,str]:
    values = {"Content-Type":"audio/mp4","Cache-Control":"no-store",
              "X-Gnarly-Playback-Source":"progressive-origin",
              "X-Content-Type-Options":"nosniff"}
    for name in OUTPUT_HEADERS:
        value = upstream.headers.get(name)
        if value is not None:
            values[name] = value
    if upstream.status_code == 206 and not values.get("content-range"):
        raise ValueError("Partial response without Content-Range")
    if upstream.status_code == 200 and "content-range" in values:
        raise ValueError("Invalid full response with Content-Range")
    return values

def safe_range(raw: str | None) -> str | None:
    if raw is None:
        return None
    if len(raw) > 48 or RANGE_PATTERN.fullmatch(raw) is None:
        raise ValueError("Unsupported Range")
    return raw
