"""Regression tests for anonymous, bounded GNARLY startup feedback."""
import unittest

from streaming_metrics import StreamingMetrics


class StreamingFeedbackTests(unittest.TestCase):
    def setUp(self):
        self.metrics = StreamingMetrics(now=lambda: 100)

    def report(self, event, ms=30000, source="fast_edge"):
        self.metrics.client({"event": event, "source": source, "ms": ms, "code": 0})

    def test_hints_remain_baseline_without_enough_data(self):
        for _ in range(19):
            self.report("pc_ready")
        self.assertEqual(self.metrics.playback_hints()["pc_poll_ms"], 2300)

    def test_repeated_late_pc_completion_shortens_only_readiness_poll(self):
        for i in range(20):
            self.report("pc_ready", 32000 if i < 10 else 18000,
                        "fast_edge" if i % 2 else "render")
        advice = self.metrics.playback_hints()
        self.assertEqual(advice["pc_poll_ms"], 1600)
        self.assertEqual(advice["sample_size"], 20)
        self.assertEqual(advice["mode"], "faster_ready_detection")

    def test_fast_samples_keep_original_policy(self):
        for _ in range(35):
            self.report("pc_ready", 2200)
        self.assertEqual(self.metrics.playback_hints()["pc_poll_ms"], 2300)

    def test_rebuffer_phase_appears_in_aggregate_only(self):
        self.report("rebuffer", 1450)
        snap = self.metrics.snapshot()
        self.assertIn("rebuffer/fast_edge", snap["client"])
        self.assertNotIn("track_id", str(snap))
        with self.assertRaises(ValueError):
            self.metrics.client({
                "event": "pc_ready", "source": "fast_edge", "ms": 3,
                "code": 0, "video_id": "secret"
            })


if __name__ == "__main__":
    unittest.main()
