"""Contrato de sugestões: python -m unittest discover -s backend -p 'test_*.py'."""
import threading
import unittest
from unittest.mock import patch

import yt_dlp
from fastapi.testclient import TestClient

import main


SEED = "jNQXAC9IVRw"
SOURCE = f"https://www.youtube.com/watch?v={SEED}"


class RelatedTests(unittest.TestCase):
    def setUp(self):
        self.client = TestClient(main.app)
        self.slots = patch.object(main, "_related_slots", threading.BoundedSemaphore(1))
        self.slots.start()
        self.addCleanup(self.slots.stop)

    def test_supported_video_links(self):
        for link in [SOURCE, f"https://youtu.be/{SEED}?si=abc",
                     f"https://music.youtube.com/watch?v={SEED}&list=RD{SEED}",
                     f"https://www.youtube.com/shorts/{SEED}",
                     f"https://www.youtube.com/live/{SEED}",
                     f"https://www.youtube.com/embed/{SEED}"]:
            with self.subTest(link=link):
                self.assertEqual(main._youtube_video_id(link), SEED)

    def test_invalid_targets_never_reach_extractor(self):
        with patch.object(main.yt_dlp, "YoutubeDL") as extractor:
            for link in ["https://example.com/watch?v=" + SEED,
                         "https://youtube.com.evil.test/watch?v=" + SEED,
                         "https://youtube.com/playlist?list=abc",
                         "https://youtube.com/watch?v=invalid",
                         "https://user@youtube.com/watch?v=" + SEED,
                         "https://youtube.com:8443/watch?v=" + SEED]:
                with self.subTest(link=link):
                    self.assertEqual(self.client.get("/related", params={"url": link}).status_code, 400)
            extractor.assert_not_called()

    def test_missing_and_malformed_query(self):
        self.assertEqual(self.client.get("/related").status_code, 422)
        self.assertEqual(self.client.get("/related", params={"url": "not a url"}).status_code, 422)

    def test_contract_and_flat_no_download_options(self):
        entry = {"id": "abcdefghijk", "title": " Próxima música ",
                 "thumbnails": [{"url": "https://i.ytimg.com/vi/abcdefghijk/hqdefault.jpg"}]}
        with patch.object(main.yt_dlp, "YoutubeDL") as extractor:
            ydl = extractor.return_value.__enter__.return_value
            ydl.extract_info.return_value = {"entries": [{"id": SEED, "title": "Atual"}, entry, entry]}
            response = self.client.get("/related", params={"url": SOURCE})
            self.assertEqual(response.status_code, 200)
            self.assertEqual(response.json(), [{"title": "Próxima música",
                "thumbnail": "https://i.ytimg.com/vi/abcdefghijk/hqdefault.jpg",
                "url": "https://www.youtube.com/watch?v=abcdefghijk"}])
            options = extractor.call_args.args[0]
            self.assertTrue(options["extract_flat"])
            self.assertTrue(options["skip_download"])
            self.assertEqual(options["playlistend"], main.RELATED_SCAN_LIMIT)
            ydl.extract_info.assert_called_once_with(SOURCE + "&list=RD" + SEED, download=False)

    def test_filters_and_thumbnail_fallback(self):
        entries = [None, {"id": "bad", "title": "Invalid"},
                   {"id": "aaaaaaaaaaa", "title": "Live", "is_live": True},
                   {"id": "bbbbbbbbbbb", "title": "Private", "availability": "private"},
                   {"id": "ccccccccccc", "title": "Long", "duration": main.MAX_DURATION_SECONDS + 1},
                   {"id": "ddddddddddd", "title": " "},
                   {"id": "eeeeeeeeeee", "title": "Valid", "thumbnail": "http://example.com/image.jpg"}]
        result = main._related_entries({"entries": entries}, SEED)
        self.assertEqual(len(result), 1)
        self.assertEqual(str(result[0].thumbnail), "https://i.ytimg.com/vi/eeeeeeeeeee/hqdefault.jpg")

    def test_caps_results_and_lazy_iteration(self):
        def entries():
            for i in range(10):
                yield {"id": f"{i:011d}", "title": str(i)}
            raise AssertionError("Must not exhaust an infinite Mix")
        self.assertEqual(len(main._related_entries({"entries": entries()}, SEED)), 10)

    def test_caps_scan_when_entries_unusable(self):
        def entries():
            for _ in range(main.RELATED_SCAN_LIMIT):
                yield None
            raise AssertionError("Scan limit exceeded")
        self.assertEqual(main._related_entries({"entries": entries()}, SEED), [])

    def test_upstream_errors_release_slot(self):
        for error, code in [(yt_dlp.utils.DownloadError("blocked"), 502), (RuntimeError("broken"), 503)]:
            with self.subTest(code=code), patch.object(main.yt_dlp, "YoutubeDL") as extractor:
                extractor.return_value.__enter__.return_value.extract_info.side_effect = error
                response = self.client.get("/related", params={"url": SOURCE})
                self.assertEqual(response.status_code, code)
                self.assertTrue(main._related_slots.acquire(blocking=False))
                main._related_slots.release()

    def test_busy_does_not_block_download_slots(self):
        main._related_slots.acquire()
        self.assertEqual(self.client.get("/related", params={"url": SOURCE}).status_code, 429)
        self.assertEqual(main.download_semaphore._value, min(main.MAX_CONCURRENT_DOWNLOADS, 2))

    def test_empty_mix_is_valid_empty_list(self):
        with patch.object(main.yt_dlp, "YoutubeDL") as extractor:
            extractor.return_value.__enter__.return_value.extract_info.return_value = {"entries": []}
            self.assertEqual(self.client.get("/related", params={"url": SOURCE}).json(), [])


if __name__ == "__main__":
    unittest.main()
