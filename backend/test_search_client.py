"""Offline regression tests for pooled YT Music metadata and single-flight search."""
from concurrent.futures import ThreadPoolExecutor
import threading
import time
import unittest
from unittest.mock import MagicMock, patch

from fastapi.testclient import TestClient

import main
import ytm_client


SONG = {
    "resultType": "song",
    "videoId": "abcdefghijk",
    "title": "Coalesced Track",
    "artists": [{"name": "Test Artist"}],
    "duration_seconds": 190,
}


class ClientPoolTests(unittest.TestCase):
    def tearDown(self):
        ytm_client.invalidate()

    def test_exclusive_leases_reuse_idle_sessions(self):
        with patch("ytmusicapi.YTMusic", side_effect=[MagicMock(), MagicMock()]) as factory:
            with ytm_client.acquire() as first:
                with ytm_client.acquire() as second:
                    self.assertIsNot(first, second)
                with ytm_client.acquire() as reused:
                    self.assertIs(reused, second)
            self.assertEqual(factory.call_count, 2)

    def test_failed_client_is_recreated(self):
        with patch("ytmusicapi.YTMusic", side_effect=[MagicMock(), MagicMock()]) as factory:
            with ytm_client.acquire() as first:
                ytm_client.invalidate(first)
            with ytm_client.acquire() as second:
                self.assertIsNot(first, second)
            self.assertEqual(factory.call_count, 2)


class SearchSingleFlightTests(unittest.TestCase):
    def setUp(self):
        self.client = TestClient(main.app)
        with main._search_results_lock:
            main._search_results_cache.clear()
            main._search_inflight.clear()
        ytm_client.invalidate()

    def tearDown(self):
        ytm_client.invalidate()

    def test_two_simultaneous_identical_queries_call_upstream_once(self):
        started = threading.Event()
        release = threading.Event()
        fake = MagicMock()

        def slow_search(*_args, **_kwargs):
            started.set()
            if not release.wait(timeout=4):
                raise AssertionError("Simulated search was not released")
            return [SONG]

        fake.search.side_effect = slow_search
        with patch("ytmusicapi.YTMusic", return_value=fake) as factory:
            before = main._search_stats["coalesced"]
            with ThreadPoolExecutor(max_workers=2) as pool:
                first = pool.submit(self.client.get, "/search",
                                    params={"query": "Coalesced Track"})
                try:
                    self.assertTrue(started.wait(timeout=3))
                    second = pool.submit(self.client.get, "/search",
                                         params={"query": "Coalesced Track"})
                    deadline = time.monotonic() + 3
                    while main._search_stats["coalesced"] == before and time.monotonic() < deadline:
                        time.sleep(0.01)
                finally:
                    release.set()
                a, b = first.result(timeout=6), second.result(timeout=6)
            self.assertEqual((a.status_code, b.status_code), (200, 200))
            self.assertEqual(a.text, b.text)
            self.assertEqual(factory.call_count, 1)
            self.assertEqual(fake.search.call_count, 1)
            self.assertIn("COALESCED", [a.headers["X-Search-Cache"],
                                       b.headers["X-Search-Cache"]])

    def test_failed_upstream_does_not_poison_next_search(self):
        fake = MagicMock()
        fake.search.side_effect = [RuntimeError("mock upstream outage"), [SONG]]
        with patch("ytmusicapi.YTMusic", return_value=fake) as factory:
            failed = self.client.get("/search", params={"query": "retryable track"})
            recovered = self.client.get("/search", params={"query": "retryable track"})
        self.assertEqual(failed.status_code, 502)
        self.assertEqual(recovered.status_code, 200)
        self.assertIn("Coalesced Track", recovered.text)
        self.assertEqual(fake.search.call_count, 2)
        self.assertEqual(factory.call_count, 2)

    def test_search_metrics_do_not_expose_tokens(self):
        response = self.client.get("/metrics")
        self.assertEqual(response.status_code, 200)
        stats = response.json()["search"]
        for key in ("hit", "miss", "coalesced", "busy", "errors",
                    "upstream_ms_last", "client_builds", "inflight"):
            self.assertIn(key, stats)


if __name__ == "__main__":
    unittest.main()
