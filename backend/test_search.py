"""Offline contracts for native search and background downloads."""
import subprocess
import threading
import unittest
from unittest.mock import patch

from fastapi.testclient import TestClient
from fastapi.responses import Response
import main


class SearchTests(unittest.TestCase):
    def setUp(self):
        self.client = TestClient(main.app)
        slots = patch.object(main, "_search_slots", threading.BoundedSemaphore(1))
        slots.start()
        self.addCleanup(slots.stop)

    def test_ndjson_and_song_filter(self):
        from unittest.mock import MagicMock
        client = MagicMock()
        client.search.return_value = [
            {"resultType": "song", "videoId": "abcdefghijk", "title": "Song",
             "duration_seconds": 180, "thumbnails": [{"url": "https://example.com/a.jpg"}]},
        ]
        with patch("ytmusicapi.YTMusic", return_value=client):
            response = self.client.get("/search", params={"query": "music"})
        self.assertEqual(response.status_code, 200)
        self.assertIn("application/x-ndjson", response.headers["content-type"])
        self.assertEqual(response.json() if False else len(response.text.splitlines()), 1)
        self.assertIn('"id": "abcdefghijk"', response.text)
        client.search.assert_called_once_with("music", filter="songs", limit=20)

    def test_search_filters_long_and_missing_duration(self):
        songs = [
            {"resultType": "song", "videoId": "abcdefghijk", "title": "Long", "duration_seconds": 600},
            {"resultType": "song", "videoId": "lmnopqrstuv", "title": "Short", "duration_seconds": 599},
            {"resultType": "song", "videoId": "zzzzzzzzzzz", "title": "Unknown"},
        ]
        with patch("ytmusicapi.YTMusic") as factory:
            factory.return_value.search.return_value = songs
            response = self.client.get("/search", params={"query": "music"})
        self.assertEqual(response.status_code, 200)
        self.assertNotIn("Long", response.text)
        self.assertNotIn("Unknown", response.text)
        self.assertIn("Short", response.text)

    def test_invalid_queries_never_execute(self):
        with patch("ytmusicapi.YTMusic") as factory:
            for query in ['', '   ', 'a' * 201]:
                self.assertIn(self.client.get('/search', params={'query': query}).status_code, [400, 422])
            self.assertEqual(self.client.get('/search').status_code, 422)
            factory.assert_not_called()

    def test_failure_releases_slot(self):
        with patch("ytmusicapi.YTMusic", side_effect=RuntimeError("blocked")):
            self.assertEqual(self.client.get("/search", params={"query": "music"}).status_code, 502)
        self.assertTrue(main._search_slots.acquire(blocking=False))
        main._search_slots.release()

    def test_search_does_not_consume_audio_slots(self):
        main._search_slots.acquire()
        with patch("ytmusicapi.YTMusic") as factory:
            self.assertEqual(self.client.get('/search', params={'query': 'music'}).status_code, 429)
            factory.assert_not_called()
        self.assertEqual(main.download_semaphore._value, min(main.MAX_CONCURRENT_DOWNLOADS, 2))

    def test_get_download_reuses_existing_audio_bridge(self):
        url = 'https://www.youtube.com/watch?v=abcdefghijk'
        with patch.object(main, 'download', return_value=Response(b'fake', media_type='audio/mp4')) as download:
            response = self.client.get('/download', params={'url': url})
            self.assertEqual(response.status_code, 200)
            self.assertEqual(str(download.call_args.args[0].url), url)

    def test_get_download_rejects_invalid_sources(self):
        with patch.object(main, 'download') as download:
            for url in ['https://example.com/video', 'https://youtube.com/playlist?list=x',
                        'https://youtube.com/watch?v=invalid', 'https://user@youtube.com/watch?v=abcdefghijk']:
                self.assertEqual(self.client.get('/download', params={'url': url}).status_code, 400)
            download.assert_not_called()


if __name__ == '__main__':
    unittest.main()
