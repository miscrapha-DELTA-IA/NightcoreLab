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
        main.audio_sources._metadata.clear()
        main._youtube_cooldown_until = 0
        main._strategy_failures.clear()
        main._strategy_disabled_until.clear()
        self.addCleanup(setattr, main, "_youtube_cooldown_until", 0)

    def test_player_client_circuit_opens_and_success_resets(self):
        label = "logado/web"
        for _ in range(3):
            main._strategy_outcome(label, False, True)
        self.assertFalse(main._strategy_available(label))
        self.assertGreater(main._circuit_snapshot()[label]["open_seconds"], 0)
        main._strategy_outcome(label, True)
        self.assertTrue(main._strategy_available(label))

    def test_related_429_isolated_from_download_circuit(self):
        main._youtube_cooldown_until = 0
        main._YtdlpLog("related").warning("HTTP Error 429: Too Many Requests")
        self.assertEqual(main._youtube_cooldown_until, 0)
        # A metadata crawler may be limited independently while the user
        # is still allowed to start an explicitly requested download.
        main._check_youtube_cooldown()

    def test_read_only_browser_status_explains_429_without_extraction(self):
        import json
        import time
        with patch.object(main, "_youtube_cooldown_until", time.monotonic() + 98), \
             patch.object(main, "_extract_m4a", side_effect=AssertionError("no extraction")), \
             patch.object(main, "_try_r2", side_effect=AssertionError("no R2 probe")):
            response = main.playback_status()
        payload = json.loads(response.body)
        self.assertEqual(response.status_code, 200)
        self.assertEqual(payload["status"], "upstream_rate_limited")
        self.assertGreaterEqual(payload["retry_after"], 97)
        self.assertEqual(response.headers["retry-after"], str(payload["retry_after"]))
        self.assertEqual(response.headers["cache-control"], "no-store")
        self.assertTrue(payload["cached_tracks_may_play"])

    def test_read_only_browser_status_returns_ready_after_cooldown(self):
        import json
        with patch.object(main, "_youtube_cooldown_until", 0):
            response = main.playback_status()
        self.assertEqual(json.loads(response.body)["status"], "ready")
        self.assertNotIn("retry-after", response.headers)

    def test_real_audio_client_429_still_protects_backend(self):
        main._YtdlpLog("logado/web").warning("HTTP Error 429: Too Many Requests")
        with self.assertRaises(HTTPException) as raised:
            main._check_youtube_cooldown()
        self.assertEqual(raised.exception.status_code, 429)
        self.assertEqual(raised.exception.headers["X-Download-Error"],
                         "upstream_rate_limited")

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

    def test_web_shortcut_keeps_default_client_when_web_has_no_audio(self):
        result = (Path("song.m4a"), "song", None)
        with tempfile.TemporaryDirectory() as folder:
            cookies = Path(folder) / "cookies.txt"
            cookies.write_text("# Netscape HTTP Cookie File\n", encoding="utf-8")
            with patch.object(main, "COOKIES_FILE", str(cookies)), \
                 patch.object(main, "_extract_with", side_effect=[
                     HTTPException(status_code=422, detail="Não foi possível obter o áudio em formato .m4a."),
                     result]) as extract:
                self.assertEqual(main._extract_m4a("url", folder), result)
        self.assertEqual(extract.call_count, 2)
        self.assertEqual(extract.call_args_list[0].args[-1], ["web"])
        self.assertIsNone(extract.call_args_list[1].args[-1])

    def test_web_shortcut_keeps_default_client_on_upstream_error(self):
        result = (Path("song.m4a"), "song", None)
        with tempfile.TemporaryDirectory() as folder:
            cookies = Path(folder) / "cookies.txt"
            cookies.write_text("# Netscape HTTP Cookie File\n", encoding="utf-8")
            with patch.object(main, "COOKIES_FILE", str(cookies)), \
                 patch.object(main, "_extract_with", side_effect=[
                     main.yt_dlp.utils.DownloadError("Web player unavailable"), result]) as extract:
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
