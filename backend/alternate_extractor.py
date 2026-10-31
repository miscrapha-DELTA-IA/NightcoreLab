"""Independent, tightly bounded same-recording audio fallback via pytubefix.

This is a distinct extraction implementation, not a second yt-dlp wrapper.
Only attempted after a non-throttle yt-dlp format/metadata failure. Never
retries a confirmed HTTP 429, provider challenge, or global cooldown.

Run pytubefix in a killable child process to avoid stuck requests outliving
the player and consuming the entire Render worker pool. Never log URL tokens,
cookie contents, or signed GoogleVideo media URLs.
"""
from __future__ import annotations

import json
import os
from pathlib import Path
import re
import subprocess
import sys
import threading

_VIDEO = re.compile(r"^[A-Za-z0-9_-]{11}$")
_SUCCESS = {"success": 0, "failure": 0, "timeout": 0, "skipped": 0}
_lock = threading.Lock()


def _count(key: str) -> None:
    with _lock:
        _SUCCESS[key] += 1


def snapshot() -> dict:
    with _lock:
        return dict(_SUCCESS)


def enabled() -> bool:
    return os.getenv("GNARLY_ALTERNATE_EXTRACTOR", "1").strip().lower() not in {
        "0", "false", "no", "off"
    }


def should_attempt(error: BaseException) -> bool:
    """Fallback only when a different parser may help; never flood a throttle."""
    if not enabled():
        return False
    status = getattr(error, "status_code", None)
    if status is not None and status not in (422, 502, 503):
        return False
    message = str(getattr(error, "detail", error)).lower()
    denied = ("http error 429", "too many requests", "rate limit",
              "not a bot", "bot verification", "sign in", "private video",
              "age restricted", "http error 403", "forbidden",
              "region", "country", "download limit")
    if any(token in message for token in denied):
        return False
    return any(token in message for token in (
        "requested format is not available",
        "no video formats found",
        "failed to extract any player response",
        "only images are available",
        "não foi possível obter o áudio em formato .m4a",
        "no audio formats", "format not available",
    ))


def _valid_output(path: Path, work_dir: Path, video_id: str) -> bool:
    try:
        if path.resolve() != (work_dir / f"{video_id}.m4a").resolve():
            return False
        size = path.stat().st_size
        if not 1024 <= size <= 72 * 1024 * 1024:
            return False
        with path.open("rb") as fp:
            header = fp.read(12)
        return len(header) >= 12 and header[4:8] == b"ftyp"
    except (OSError, ValueError):
        return False


def extract(video_id: str, work_dir: str, *, timeout: int = 36):
    """Return (audio Path, title, thumbnail), or None. Never raises to caller."""
    if not enabled() or not _VIDEO.fullmatch(video_id):
        _count("skipped")
        return None
    target = Path(work_dir)
    target.mkdir(parents=True, exist_ok=True)
    # Isolate metadata fetch + media transfer under one hard wall-clock bound.
    # No shell, arbitrary URLs, OAuth, cookies, proxies, or runtime config.
    try:
        result = subprocess.run(
            [sys.executable, "-m", "alternate_extractor", "--worker",
             video_id, str(target)],
            stdin=subprocess.DEVNULL, capture_output=True, text=True,
            timeout=max(8, min(45, timeout)), check=False,
        )
        if result.returncode != 0 or len(result.stdout) > 4096:
            _count("failure")
            return None
        info = json.loads(result.stdout.strip())
        path = target / f"{video_id}.m4a"
        if not _valid_output(path, target, video_id):
            _count("failure")
            return None
        title = info.get("title")
        thumbnail = info.get("thumbnail")
        _count("success")
        return path, (title if isinstance(title, str) and title.strip()
                      else video_id)[:180], (thumbnail if isinstance(thumbnail, str)
                                            and thumbnail.startswith("https://") else None)
    except subprocess.TimeoutExpired:
        _count("timeout")
        return None
    except (OSError, ValueError, TypeError, json.JSONDecodeError):
        _count("failure")
        return None


def run_worker(video_id: str, destination: str, factory=None) -> int:
    """Child process only: a second parser; no external secrets or account state."""
    if not _VIDEO.fullmatch(video_id):
        return 2
    try:
        if factory is None:
            from pytubefix import YouTube
            factory = YouTube
        target = Path(destination)
        target.mkdir(parents=True, exist_ok=True)
        yt = factory(f"https://www.youtube.com/watch?v={video_id}",
                     use_oauth=False, allow_oauth_cache=False)
        duration = int(yt.length)
        if not 0 < duration < 600:
            return 3
        audio = yt.streams.get_audio_only(subtype="mp4")
        if audio is None:
            return 4
        size = getattr(audio, "filesize", 0) or 0
        if size and size > 72 * 1024 * 1024:
            return 5
        path = audio.download(output_path=str(target),
                              filename=f"{video_id}.m4a",
                              timeout=12, max_retries=0)
        expected = target / f"{video_id}.m4a"
        if not path or not _valid_output(expected, target, video_id):
            return 6
        print(json.dumps({"title": str(yt.title)[:180],
                          "thumbnail": str(yt.thumbnail_url)[:1024]}))
        return 0
    except Exception:
        # Detailed errors may contain signed media URLs; keep subprocess silent.
        return 7


if __name__ == "__main__":
    if len(sys.argv) != 4 or sys.argv[1] != "--worker":
        sys.exit(2)
    sys.exit(run_worker(sys.argv[2], sys.argv[3]))
