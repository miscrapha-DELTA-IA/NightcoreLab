"""Offline playback latency regressions, including concurrent cache misses."""
import asyncio
from pathlib import Path
from unittest.mock import AsyncMock, patch

from fastapi import BackgroundTasks
import main

URL = "https://www.youtube.com/watch?v=abcdefghijk"


def test_resident_audio_never_waits_for_remote_cache():
    async def scenario():
        remote = AsyncMock(side_effect=AssertionError("Local playback must not await R2"))
        tasks = BackgroundTasks()
        with patch.object(main, "_pin_cached_audio", return_value=(Path("cached.m4a"), "Song", None, "")), \
             patch.object(main, "_try_r2", remote), \
             patch.object(main, "_schedule_r2_upload"), \
             patch.object(main, "_release_cached_reader"):
            response = await main.download(main.DownloadRequest(url=URL), tasks)
            assert response.path == Path("cached.m4a")
            remote.assert_not_awaited()
            await tasks()
    asyncio.run(scenario())


def test_slow_remote_cache_has_a_bounded_lookup():
    class SlowR2:
        async def find(self, _key):
            await asyncio.Event().wait()

    async def scenario():
        with patch.object(main, "r2_cache", SlowR2()), \
             patch.object(main, "R2_LOOKUP_TIMEOUT_SECONDS", 0.01):
            # An unbounded HEAD hangs this outer deadline instead of falling back.
            assert await asyncio.wait_for(main._try_r2("abcdefghijk", "audio"), 0.5) is None
    asyncio.run(scenario())


def test_concurrent_remote_misses_share_one_extraction():
    async def scenario():
        remote_arrivals = 0
        remote_barrier = asyncio.Event()
        release_extraction = asyncio.Event()
        extraction_count = 0

        async def remote_miss(*_args):
            nonlocal remote_arrivals
            remote_arrivals += 1
            if remote_arrivals == 2:
                remote_barrier.set()
            await remote_barrier.wait()
            return None

        async def extract(_url):
            nonlocal extraction_count
            extraction_count += 1
            await release_extraction.wait()
            return Path("cached.m4a"), "Song", None, ""

        with patch.object(main, "_pin_cached_audio", return_value=None), \
             patch.object(main, "_try_r2", remote_miss), \
             patch.object(main, "_shared_extraction", extract), \
             patch.object(main, "_rss_bytes", return_value=0), \
             patch.object(main, "_check_youtube_cooldown"), \
             patch.dict(main.in_flight_downloads, {}, clear=True):
            responses = [BackgroundTasks(), BackgroundTasks()]
            requests = [asyncio.create_task(main.download(main.DownloadRequest(url=URL), task))
                        for task in responses]
            await asyncio.wait_for(remote_barrier.wait(), 0.5)
            for _ in range(10):
                await asyncio.sleep(0)
            release_extraction.set()
            try:
                await asyncio.wait_for(asyncio.gather(*requests), 0.5)
                assert extraction_count == 1
                for tasks in responses:
                    await tasks()
            finally:
                for request in requests:
                    request.cancel()
                await asyncio.gather(*requests, return_exceptions=True)
    asyncio.run(scenario())
