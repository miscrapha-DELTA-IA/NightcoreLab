"""Offline tests for provider-aware outbound monitoring and safe cached playback."""
import asyncio
import unittest
from unittest.mock import AsyncMock, patch

from fastapi.responses import Response
from fastapi.testclient import TestClient

import main
import upstream_health
import ytm_client


class UpstreamClassificationTests(unittest.TestCase):
    def setUp(self):
        upstream_health.reset_for_tests()
        ytm_client.invalidate()

    def tearDown(self):
        upstream_health.reset_for_tests()
        ytm_client.invalidate()

    def test_classifies_status_without_storing_secret_error_messages(self):
        self.assertEqual(upstream_health.classify_error(
            RuntimeError("HTTP Error 429: Too Many Requests https://secret.invalid/?token=private")),
            "rate_limited")
        self.assertEqual(upstream_health.classify_error(
            RuntimeError("HTTP Error 403: Forbidden")), "access_denied")
        self.assertEqual(upstream_health.classify_error(TimeoutError("timed out")), "timeout")
        self.assertEqual(upstream_health.classify_error(RuntimeError("unknown")), "upstream_error")
        upstream_health.record_failure(
            "youtube_audio", RuntimeError("HTTP Error 403 secret-cookie=never-log-me"))
        stats = str(upstream_health.snapshot())
        self.assertIn("access_denied", stats)
        self.assertNotIn("never-log-me", stats)
        self.assertNotIn("secret-cookie", stats)

    def test_audio_and_r2_outages_do_not_block_search(self):
        upstream_health.record_failure("youtube_audio", RuntimeError("HTTP Error 429"))
        upstream_health.record_failure("r2_cache", RuntimeError("HTTP Error 403"))
        self.assertEqual(upstream_health.remaining("ytmusic_search"), 0)
        self.assertEqual(upstream_health.remaining("youtube_audio"), 0)
        self.assertEqual(upstream_health.remaining("r2_cache"), 0)

    def test_success_resets_search_cooldown(self):
        upstream_health.record_failure("ytmusic_search", RuntimeError("HTTP Error 429"))
        seconds, reason = upstream_health.cooldown("ytmusic_search")
        self.assertGreater(seconds, 0)
        self.assertEqual(reason, "rate_limited")
        upstream_health.record_success("ytmusic_search", 34)
        self.assertEqual(upstream_health.remaining("ytmusic_search"), 0)
        self.assertEqual(upstream_health.snapshot()["ytmusic_search"]["last_latency_ms"], 34)

    def test_egress_profile_has_no_ip_or_rotation_claims(self):
        with patch.dict("os.environ", {"EGRESS_MODE": "unknown", "RENDER_REGION": "oregon"}):
            profile = upstream_health.egress_profile()
        self.assertEqual(profile["mode"], "unverified")
        self.assertEqual(profile["region"], "oregon")
        self.assertFalse(profile["ip_rotation"])
        self.assertEqual(profile["ip_reputation"], "not_measured")


class BackendEgressTests(unittest.TestCase):
    def setUp(self):
        upstream_health.reset_for_tests()
        ytm_client.invalidate()
        self.client = TestClient(main.app)
        with main._search_results_lock:
            main._search_results_cache.clear()
            main._search_inflight.clear()

    def tearDown(self):
        upstream_health.reset_for_tests()
        ytm_client.invalidate()

    def test_real_upstream_429_is_labeled_and_next_request_does_not_retry(self):
        with patch("ytmusicapi.YTMusic") as factory:
            factory.return_value.search.side_effect = RuntimeError("HTTP Error 429 Too Many Requests")
            first = self.client.get("/search", params={"query": "Blocked recording"})
            second = self.client.get("/search", params={"query": "Different recording"})
        self.assertEqual(first.status_code, 429)
        self.assertEqual(first.headers["X-Search-Error"], "upstream_rate_limited")
        self.assertGreater(int(first.headers["Retry-After"]), 0)
        self.assertEqual(second.status_code, 429)
        self.assertEqual(second.headers["X-Search-Error"], "upstream_rate_limited")
        self.assertEqual(factory.return_value.search.call_count, 1)

    def test_upstream_403_does_not_get_mislabeled_as_429(self):
        with patch("ytmusicapi.YTMusic") as factory:
            factory.return_value.search.side_effect = RuntimeError("HTTP Error 403 Forbidden")
            first = self.client.get("/search", params={"query": "Denied recording"})
            second = self.client.get("/search", params={"query": "Another recording"})
        self.assertEqual(first.status_code, 503)
        self.assertEqual(second.status_code, 503)
        self.assertEqual(first.headers["X-Search-Error"], "upstream_access_denied")
        self.assertEqual(second.headers["X-Search-Error"], "upstream_access_denied")
        self.assertEqual(factory.return_value.search.call_count, 1)

    def test_metrics_are_aggregate_and_do_not_expose_ip(self):
        stats = self.client.get("/metrics").json()
        self.assertIn("upstream_health", stats)
        self.assertIn("egress", stats)
        self.assertEqual(set(stats["upstream_health"]),
                         {"ytmusic_search", "youtube_audio", "r2_cache"})
        self.assertNotIn("ip_address", str(stats["egress"]))
        self.assertNotIn("cookies", str(stats["upstream_health"]))

    def test_download_uses_r2_before_any_youtube_cooldown(self):
        async_response = AsyncMock(return_value=Response(content=b"cached", media_type="audio/mp4"))
        with (patch.object(main, "_try_r2", async_response),
             patch.object(main, "_check_youtube_cooldown",
                          side_effect=AssertionError("No upstream lookup on cached song"))):
            response = self.client.post(
                "/download", json={"url": "https://www.youtube.com/watch?v=abcdefghijk"})
        self.assertEqual(response.status_code, 200)
        self.assertEqual(response.content, b"cached")
        async_response.assert_awaited_once()


if __name__ == "__main__":
    unittest.main()
