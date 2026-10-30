"""Bounded, exclusively leased YT Music clients for fast metadata search.

A ytmusicapi search initializes visitor headers lazily, which may require an
extra GET before its search POST. Reusing a client avoids repeating that work.
A Requests Session is not leased to multiple searches concurrently.
"""
from __future__ import annotations

from contextlib import contextmanager
from functools import partial
import os
import threading
from typing import Iterator

import requests
import ytmusicapi

_lock = threading.RLock()
_entries: list[dict] = []
_builds = 0
_MAX_CLIENTS = 3


def _timeout() -> float:
    try:
        seconds = float(os.getenv("YTMUSIC_HTTP_TIMEOUT", "8"))
    except ValueError:
        seconds = 8
    return max(2.0, min(seconds, 15.0))


def _retire(entry: dict) -> None:
    entry["retired"] = True
    if not entry["busy"]:
        _entries.remove(entry)
        entry["session"].close()


@contextmanager
def acquire() -> Iterator[ytmusicapi.YTMusic]:
    """Lease a dedicated session, reused only after the prior request completes.

    A change of the YTMusic factory (also used by isolated tests) invalidates
    old sessions. Callers must already own a search-concurrency slot.
    """
    global _builds
    with _lock:
        factory = ytmusicapi.YTMusic
        for entry in list(_entries):
            if entry["factory"] is not factory and not entry["retired"]:
                _retire(entry)
        entry = next((e for e in _entries
                      if e["factory"] is factory and not e["busy"] and not e["retired"]), None)
        if entry is None:
            count = sum(e["factory"] is factory and not e["retired"] for e in _entries)
            if count >= _MAX_CLIENTS:
                raise RuntimeError("YT Music metadata client pool exhausted")
            session = requests.Session()
            session.request = partial(session.request, timeout=_timeout())
            try:
                client = factory(requests_session=session)
            except BaseException:
                session.close()
                raise
            entry = {"factory": factory, "client": client, "session": session,
                     "busy": False, "retired": False}
            _entries.append(entry)
            _builds += 1
        entry["busy"] = True
    try:
        yield entry["client"]
    finally:
        with _lock:
            entry["busy"] = False
            if entry["retired"]:
                _retire(entry)


def invalidate(client=None) -> None:
    """Discard failed connection/header state before the next lookup."""
    with _lock:
        for entry in list(_entries):
            if client is None or entry["client"] is client:
                _retire(entry)


def builds() -> int:
    with _lock:
        return _builds
