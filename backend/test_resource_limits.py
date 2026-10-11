"""Resource limits for a 512 MiB Render instance; network-free tests."""
import unittest
from unittest.mock import patch

import main


class ResourceLimitTests(unittest.TestCase):
    def test_worker_pool_and_fragment_budget(self):
        self.assertEqual(main.executor._max_workers, 2)
        self.assertEqual(main.CONCURRENT_FRAGMENTS, 2)
        self.assertLessEqual(main.MAX_CONCURRENT_DOWNLOADS, 2)
        self.assertGreaterEqual(main.MAX_CONCURRENT_DOWNLOADS, 1)
        self.assertEqual(main.MAX_PENDING_DOWNLOADS, 4)

    def test_yt_dlp_gate_allows_at_most_two_heavy_workers(self):
        first = main._heavy_ytdlp_slots.acquire(blocking=False)
        second = main._heavy_ytdlp_slots.acquire(blocking=False)
        try:
            self.assertTrue(first)
            self.assertTrue(second)
            self.assertFalse(main._heavy_ytdlp_slots.acquire(blocking=False))
        finally:
            if second:
                main._heavy_ytdlp_slots.release()
            if first:
                main._heavy_ytdlp_slots.release()

    def test_semaphore_releases_after_extraction_error(self):
        with patch.object(main, "_sweep_stale_work_dirs"), \
             patch.object(main, "_extract_m4a", side_effect=RuntimeError("test failure")):
            with self.assertRaisesRegex(RuntimeError, "test failure"):
                main._run_extraction("https://www.youtube.com/watch?v=jNQXAC9IVRw")
        # Thread-level budget must never leak following worker failure.
        first = main._heavy_ytdlp_slots.acquire(blocking=False)
        second = main._heavy_ytdlp_slots.acquire(blocking=False)
        try:
            self.assertTrue(first and second)
        finally:
            if second:
                main._heavy_ytdlp_slots.release()
            if first:
                main._heavy_ytdlp_slots.release()


if __name__ == "__main__":
    unittest.main()
