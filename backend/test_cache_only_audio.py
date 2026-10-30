"""Cache-only audio lookup and transparent upstream rate-limit classification."""
import unittest
from unittest.mock import patch, AsyncMock

from fastapi.responses import Response
from fastapi.testclient import TestClient
import yt_dlp

import main


class CacheOnlyPlaybackTests(unittest.TestCase):
    def setUp(self):
        self.client=TestClient(main.app)
        self.url="https://www.youtube.com/watch?v=ABCDEFGHIJK"

    def test_cache_miss_does_not_extract_or_queue(self):
        with patch.object(main,"_try_r2",new=AsyncMock(return_value=None)), \
             patch.object(main,"_pin_cached_audio",return_value=None), \
             patch.object(main,"_shared_extraction",side_effect=AssertionError("extracted")), \
             patch.object(main,"_check_youtube_cooldown",side_effect=AssertionError("cooldown checked")):
            response=self.client.get("/download",params={"url":self.url,"cache_only":"1","delivery":"browser"})
        self.assertEqual(response.status_code,404)
        self.assertEqual(response.json()["code"],"cache_miss")

    def test_r2_hit_survives_origin_cooldown(self):
        audio=Response(b"m4a-cache",media_type="audio/mp4")
        with patch.object(main,"_try_r2",new=AsyncMock(return_value=audio)) as lookup, \
             patch.object(main,"_check_youtube_cooldown",side_effect=AssertionError("never check origin")):
            response=self.client.get("/download",params={"url":self.url,"cache_only":"1","delivery":"browser"})
        self.assertEqual(response.status_code,200)
        self.assertEqual(response.content,b"m4a-cache")
        lookup.assert_awaited_once()

    def test_local_hit_survives_origin_cooldown(self):
        with patch.object(main,"_try_r2",new=AsyncMock(return_value=None)), \
             patch.object(main,"_pin_cached_audio",
                          return_value=(main.CACHE_DIR / "ABCDEFGHIJK.m4a","Song",None,"/tmp")), \
             patch.object(main,"_audio_response",return_value=Response(b"local",media_type="audio/mp4")), \
             patch.object(main,"_check_youtube_cooldown",side_effect=AssertionError("never check origin")):
            response=self.client.get("/download",params={"url":self.url,"cache_only":"1"})
        self.assertEqual(response.status_code,200)
        self.assertEqual(response.content,b"local")


class ProgressiveRateLimitTests(unittest.TestCase):
    def setUp(self):
        self.client=TestClient(main.app)
        self.url="https://www.youtube.com/watch?v=ABCDEFGHIJK"

    def test_genuine_upstream_429_is_not_hidden_as_422(self):
        with patch.object(main,"_pin_cached_audio",return_value=None), \
             patch.object(main,"audio_sources") as sources, \
             patch.object(main,"_check_youtube_cooldown"), \
             patch.object(main,"_pause_youtube_requests") as pause, \
             patch.object(main,"_discover_progressive_aac",
                          side_effect=yt_dlp.utils.DownloadError("HTTP Error 429 Too Many Requests")):
            sources.can_recover.return_value=False
            response=self.client.get("/stream",params={"url":self.url})
        self.assertEqual(response.status_code,429)
        self.assertEqual(response.headers.get("X-Download-Error"),"upstream_rate_limited")
        pause.assert_called_once()

    def test_non_rate_limited_extract_failure_remains_fallback_422(self):
        with patch.object(main,"_pin_cached_audio",return_value=None), \
             patch.object(main,"audio_sources") as sources, \
             patch.object(main,"_check_youtube_cooldown"), \
             patch.object(main,"_discover_progressive_aac",
                          side_effect=yt_dlp.utils.DownloadError("format not available")):
            sources.can_recover.return_value=False
            response=self.client.get("/stream",params={"url":self.url})
        self.assertEqual(response.status_code,422)


if __name__=="__main__":
    unittest.main()
