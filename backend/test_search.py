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

    def test_ndjson_and_literal_query_arguments(self):
        query = 'nightcore; $(echo secret) "mix"'
        payload = '{"id":"abcdefghijk","title":"Test"}\n'
        with patch.object(main.subprocess, "run", return_value=subprocess.CompletedProcess([], 0, payload, "")) as run:
            response = self.client.get('/search', params={'query': query})
        self.assertEqual(response.status_code, 200)
        self.assertEqual(response.text, payload)
        self.assertIn('application/x-ndjson', response.headers['content-type'])
        self.assertEqual(run.call_args.args[0][3:6], [f'ytsearch15:{query}', '--dump-json', '--flat-playlist'])
        self.assertNotIn('shell', run.call_args.kwargs)
        self.assertEqual(run.call_args.kwargs['timeout'], 75)

    def test_invalid_queries_never_execute(self):
        with patch.object(main.subprocess, 'run') as run:
            for query in ['', '   ', 'a' * 201]:
                self.assertIn(self.client.get('/search', params={'query': query}).status_code, [400, 422])
            self.assertEqual(self.client.get('/search').status_code, 422)
            run.assert_not_called()

    def test_timeout_and_failure_release_slot(self):
        with patch.object(main.subprocess, 'run', side_effect=subprocess.TimeoutExpired('yt-dlp', 75)):
            self.assertEqual(self.client.get('/search', params={'query': 'music'}).status_code, 504)
        self.assertTrue(main._search_slots.acquire(blocking=False))
        main._search_slots.release()
        with patch.object(main.subprocess, 'run', return_value=subprocess.CompletedProcess([], 1, '', 'blocked')):
            self.assertEqual(self.client.get('/search', params={'query': 'music'}).status_code, 502)
        self.assertTrue(main._search_slots.acquire(blocking=False))
        main._search_slots.release()

    def test_search_does_not_consume_audio_slots(self):
        main._search_slots.acquire()
        with patch.object(main.subprocess, 'run') as run:
            self.assertEqual(self.client.get('/search', params={'query': 'music'}).status_code, 429)
            run.assert_not_called()
        self.assertTrue(main._download_slots.acquire(blocking=False))
        main._download_slots.release()

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
