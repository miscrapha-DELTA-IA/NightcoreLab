"""Offline regression tests for shared extraction and resource limits."""
import asyncio
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

from fastapi import BackgroundTasks
import main


class ResourceProtectionTests(unittest.TestCase):
    def test_same_video_uses_one_extraction(self):
        async def scenario():
            calls = 0
            started = asyncio.Event()

            async def fake_extract(url):
                nonlocal calls
                calls += 1
                started.set()
                await asyncio.sleep(0.03)
                folder = tempfile.mkdtemp(prefix="nightcore_test_")
                path = Path(folder) / "audio.m4a"
                path.write_bytes(b"test")
                return path, "Song", None, folder

            url = "https://www.youtube.com/watch?v=abcdefghijk"
            requests = [main.DownloadRequest(url=url) for _ in range(2)]
            backgrounds = [BackgroundTasks(), BackgroundTasks()]
            with patch.object(main, "_shared_extraction", fake_extract):
                a = asyncio.create_task(main.download(requests[0], backgrounds[0]))
                await started.wait()
                b = asyncio.create_task(main.download(requests[1], backgrounds[1]))
                first, second = await asyncio.gather(a, b)
                self.assertEqual(calls, 1)
                self.assertEqual(first.path, second.path)
                self.assertIn("abcdefghijk", main.in_flight_downloads)
                await backgrounds[0]()
                self.assertTrue(Path(second.path).exists())
                await backgrounds[1]()
                self.assertFalse(Path(first.path).exists())
                self.assertNotIn("abcdefghijk", main.in_flight_downloads)

        asyncio.run(scenario())

    def test_concurrent_workers_never_exceed_two(self):
        async def scenario():
            active = 0
            peak = 0

            def fake_run(url):
                import time
                time.sleep(0.02)
                return "done"

            async def unit():
                nonlocal active, peak
                async with main.download_semaphore:
                    active += 1
                    peak = max(peak, active)
                    await asyncio.sleep(0.02)
                    active -= 1

            await asyncio.gather(*(unit() for _ in range(6)))
            self.assertLessEqual(peak, 2)
        asyncio.run(scenario())


if __name__ == "__main__":
    unittest.main()
