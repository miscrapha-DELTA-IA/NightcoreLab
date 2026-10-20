import asyncio
import json
import logging
from pathlib import Path
from unittest.mock import patch

from fastapi import BackgroundTasks, HTTPException
from fastapi.testclient import TestClient
import pytest

import main
import backend_search

URL = "https://www.youtube.com/watch?v=abcdefghijk"


def test_memory_guard_rejects_new_extraction_but_not_cached_audio():
    async def scenario():
        with patch.object(main, "_rss_bytes", return_value=401 * 1024 * 1024), \
             patch.object(main, "_pin_cached_audio", return_value=None):
            with pytest.raises(HTTPException) as raised:
                await main.download(main.DownloadRequest(url=URL), BackgroundTasks())
            assert raised.value.status_code == 503
            assert raised.value.headers["Retry-After"] == "30"
        with patch.object(main, "_rss_bytes", return_value=401 * 1024 * 1024), \
             patch.object(main, "_pin_cached_audio", return_value=(Path("cached.m4a"), "Song", None, "")):
            response = await main.download(main.DownloadRequest(url=URL), BackgroundTasks())
            assert response.path == Path("cached.m4a")
    asyncio.run(scenario())


def test_queue_full_returns_retry_and_position():
    async def scenario():
        with patch.object(main, "_rss_bytes", return_value=0), \
             patch.object(main, "_pin_cached_audio", return_value=None), \
             patch.dict(main.in_flight_downloads, {str(i): None for i in range(4)}):
            with pytest.raises(HTTPException) as raised:
                await main.download(main.DownloadRequest(url=URL), BackgroundTasks())
            assert raised.value.status_code == 429
            assert raised.value.headers["Retry-After"] == "30"
            assert raised.value.headers["X-Queue-Position"] == "4"
    asyncio.run(scenario())


def test_last_consumer_cancels_queued_extraction():
    async def scenario():
        with patch.object(main, "download_semaphore", asyncio.Semaphore(0)), \
             patch.object(main, "_pin_cached_audio", return_value=None), \
             patch.object(main, "_rss_bytes", return_value=0), \
             patch.object(main, "_check_youtube_cooldown"):
            waiter = asyncio.create_task(main.download(main.DownloadRequest(url=URL), BackgroundTasks()))
            for _ in range(100):
                if "abcdefghijk" in main.in_flight_downloads:
                    break
                await asyncio.sleep(0.01)
            assert "abcdefghijk" in main.in_flight_downloads
            waiter.cancel()
            with pytest.raises(asyncio.CancelledError):
                await waiter
            await asyncio.sleep(0.01)
            assert "abcdefghijk" not in main.in_flight_downloads
    asyncio.run(scenario())


@pytest.mark.parametrize("message,status", [
    ("Private video", 404), ("Sign in to confirm your age", 403),
    ("Not available in your country", 451), ("HTTP Error 429", 429),
    ("connection timed out", 504), ("unknown extractor problem", 502),
])
def test_error_mapping(message, status):
    assert main._download_error(message).status_code == status


def test_json_search_etag_and_scoped_gzip():
    with patch.object(backend_search, "_cached_call", return_value=[{
            "id": "abcdefghijk", "title": "Long song " + "x" * 1000,
            "artist": "A", "album": None, "duration": 180,
            "thumb": None, "isSong": True, "explicit": False}]):
        with TestClient(main.app) as client:
            first = client.get("/v1/search?q=abc", headers={"Accept-Encoding": "gzip"})
            assert first.status_code == 200
            assert first.headers["content-encoding"] == "gzip"
            assert first.headers["etag"]
            again = client.get("/v1/search?q=abc", headers={"If-None-Match": first.headers["etag"]})
            assert again.status_code == 304
            assert again.content == b""


def test_structured_log_redacts_signed_urls_and_query_tokens():
    record = logging.LogRecord("uvicorn.access", logging.INFO, __file__, 1,
        'GET /download?access_token=secret HTTP/1.1 media https://r2.example/file?X-Amz-Signature=secret',
        (), None)
    payload = json.loads(main._JsonLogFormatter().format(record))
    assert payload["level"] == "INFO"
    assert "secret" not in payload["message"]
