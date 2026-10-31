"""Streaming metrics collect ONLY anonymous, bounded categories and latencies."""
import unittest
from unittest.mock import patch
from fastapi.testclient import TestClient

import main
from streaming_metrics import StreamingMetrics


GOOD = {"event": "initial_media_error", "source": "fast_edge", "ms": 32410, "code": 4}


class StreamingMetricsTests(unittest.TestCase):
    def test_aggregates_latency_without_raw_identifiers(self):
        m = StreamingMetrics()
        self.assertTrue(m.client(GOOD))
        self.assertTrue(m.client({"event": "recovered_audio", "source": "render", "ms": 35800, "code": 0}))
        m.server("/stream", 503, 12000)
        m.server("/pc-node/status", 200, 25)
        m.server("/pc-node/status/ABCDEFGHIJK", 200, 25)  # never a raw-ID key
        view = m.snapshot()
        self.assertEqual(view["client"]["initial_media_error/fast_edge"]["count"], 1)
        self.assertEqual(view["client"]["recovered_audio/render"]["over_30s"], 1)
        self.assertEqual(view["backend_headers"]["/stream/5xx"]["p50_ms"], 12000)
        self.assertNotIn("ABCDEFGHIJK", str(view))
        self.assertNotIn("http://", str(view))

    def test_refuses_personal_data_unknown_fields_nan_and_bad_categories(self):
        m = StreamingMetrics()
        cases = [
            {**GOOD, "video_id": "ABCDEFGHIJK"},
            {**GOOD, "url": "https://youtube.com/watch?v=ABCDEFGHIJK"},
            {**GOOD, "ms": float("nan")},
            {**GOOD, "source": "https://evil.example"},
            {**GOOD, "event": "private_session"},
            {**GOOD, "ms": -1},
            {**GOOD, "code": 401},
        ]
        for body in cases:
            with self.subTest(body=body), self.assertRaises(ValueError):
                m.client(body)
        self.assertEqual(m.snapshot()["client"], {})

    def test_global_rate_cap_and_percentile_window_are_bounded(self):
        clock = [20.0]
        m = StreamingMetrics(now=lambda: clock[0])
        for _ in range(180):
            self.assertTrue(m.client(GOOD))
        self.assertFalse(m.client(GOOD))
        self.assertEqual(m.snapshot()["client_dropped"], 1)
        clock[0] += 61
        self.assertTrue(m.client(GOOD))
        for index in range(400):
            m.server("/download", 200, index)
        summary = m.snapshot()["backend_headers"]["/download/2xx"]
        self.assertEqual(summary["count"], 400)
        self.assertGreaterEqual(summary["p50_ms"], 144)
        # A pathologically slow response, NaN or invalid input never breaks
        # real streaming just because its metrics could not be captured.
        m.server("/stream", 200, 9999999)
        m.server("/stream", 200, float("nan"))
        m.server("/stream", 200, None)
        self.assertEqual(m.snapshot()["backend_headers"]["/stream/2xx"]["count"], 1)

    def test_http_receiver_and_metrics_snapshot(self):
        meter = StreamingMetrics()
        with patch.object(main, "streaming_metrics", meter):
            with TestClient(main.app) as client:
                ok = client.post("/v1/playback-metric", json=GOOD)
                self.assertEqual(ok.status_code, 204)
                self.assertEqual(client.post("/v1/playback-metric",
                    json={**GOOD, "song": "private"}).status_code, 400)
                self.assertEqual(client.post("/v1/playback-metric",
                    content=b"x" * 600).status_code, 413)
                self.assertEqual(client.get("/metrics").json()["streaming"]["client"][
                    "initial_media_error/fast_edge"]["count"], 1)
                reply = client.get("/pc-node/status/ABCDEFGHIJK")
                self.assertEqual(reply.status_code, 200)
                self.assertIn("backend;dur=", reply.headers.get("server-timing", ""))
        self.assertEqual(meter.snapshot()["backend_headers"]["/pc-node/status/2xx"]["count"], 1)


if __name__ == "__main__":
    unittest.main()
