"""Regression for production's 429 -> missing player response -> misleading 422."""
import asyncio
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

from fastapi import BackgroundTasks, HTTPException
import main


class YouTubeFailureTests(unittest.TestCase):
    def setUp(self):
        main._youtube_cooldown_until = 0
        self.addCleanup(setattr, main, "_youtube_cooldown_until", 0)

    def test_429_does_not_try_more_clients_and_returns_retry_after(self):
        def blocked(*args):
            main._YtdlpLog("test").warning("HTTP Error 429: Too Many Requests")
            raise main.yt_dlp.utils.DownloadError("Failed to extract any player response")
        with tempfile.TemporaryDirectory() as folder, \
             patch.object(main, "_extract_with", side_effect=blocked) as extract:
            with self.assertRaises(HTTPException) as raised:
                main._extract_m4a("https://www.youtube.com/watch?v=abcdefghijk", folder)
        self.assertEqual(extract.call_count, 1)
        self.assertEqual(raised.exception.status_code, 429)
        self.assertGreater(int(raised.exception.headers["Retry-After"]), 0)
        self.assertEqual(raised.exception.headers["X-Download-Error"], "upstream_rate_limited")

    def test_missing_player_without_rate_limit_can_use_next_client(self):
        result = (Path("song.m4a"), "song", None)
        with tempfile.TemporaryDirectory() as folder, \
             patch.object(main, "COOKIES_FILE", ""), \
             patch.object(main, "_extract_with", side_effect=[
                 main.yt_dlp.utils.DownloadError("Failed to extract any player response"), result]) as extract:
            self.assertEqual(main._extract_m4a("url", folder), result)
        self.assertEqual(extract.call_count, 2)

    def test_private_video_does_not_retry(self):
        with tempfile.TemporaryDirectory() as folder, \
             patch.object(main, "_extract_with", side_effect=main.yt_dlp.utils.DownloadError("Private video")) as extract:
            with self.assertRaises(main.yt_dlp.utils.DownloadError):
                main._extract_m4a("url", folder)
        self.assertEqual(extract.call_count, 1)

    def test_exhausted_player_failure_is_service_error(self):
        with tempfile.TemporaryDirectory() as folder, \
             patch.object(main, "_extract_with", side_effect=main.yt_dlp.utils.DownloadError(
                 "Failed to extract any player response")):
            with self.assertRaises(HTTPException) as raised:
                main._extract_m4a("url", folder)
        self.assertEqual(raised.exception.status_code, 503)

    def test_cache_still_works_during_cooldown_and_uncached_does_not_extract(self):
        async def scenario():
            main._pause_youtube_requests()
            request = main.DownloadRequest(url="https://www.youtube.com/watch?v=abcdefghijk")
            tasks = BackgroundTasks()
            with patch.object(main, "_pin_cached_audio", return_value=(Path("song.m4a"), "Song", None, "")), \
                 patch.object(main, "_shared_extraction") as extract:
                response = await main.download(request, tasks)
                self.assertEqual(response.path, Path("song.m4a"))
                extract.assert_not_called()
                await tasks()
            with patch.object(main, "_pin_cached_audio", return_value=None), \
                 patch.object(main, "_shared_extraction") as extract:
                with self.assertRaises(HTTPException) as raised:
                    await main.download(request, BackgroundTasks())
                self.assertEqual(raised.exception.status_code, 429)
                extract.assert_not_called()
        asyncio.run(scenario())
