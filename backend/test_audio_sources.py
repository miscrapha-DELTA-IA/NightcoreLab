"""Independent recovery safety and existing worker contract regressions."""
import copy
import json
import shutil
import tempfile
import threading
import unittest
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
from unittest.mock import MagicMock, patch
from fastapi import HTTPException
import audio_sources as sources
import backend_search as search
import main

ID = 'recover1234'
TRACK = dict(id='AbC12', title='Song', duration=180, is_streamable=True,
             is_available=True, user=dict(name='Artist', is_verified=True))


class RecoveryTests(unittest.TestCase):
    def setUp(self):
        sources._metadata.clear()
        sources._misses.clear()
        sources._provider_retry_at = 0
        sources.remember(ID, 'Song', 'Artist', 180)
        main._youtube_cooldown_until = 0
        self.addCleanup(setattr, main, '_youtube_cooldown_until', 0)

    def test_matching_rejects_versions_gates_previews_and_unverified(self):
        record = sources._metadata[ID]
        self.assertTrue(sources.matches(record, TRACK))
        for field, value in [('title', 'Song (Live)'), ('duration', 30),
                             ('is_stream_gated', True), ('is_streamable', False),
                             ('is_available', False), ('is_unlisted', True),
                             ('access', {'stream': False}),
                             ('user', {'name': 'Artist', 'is_verified': False}),
                             ('user', {'name': 'Other', 'is_verified': True})]:
            with self.subTest(field=field, value=value):
                candidate = copy.deepcopy(TRACK)
                candidate[field] = value
                self.assertFalse(sources.matches(record, candidate))

    def test_untrusted_redirect_never_requested(self):
        session = MagicMock()
        response = session.get.return_value
        response.status_code = 302
        response.url = sources.API + '/tracks/x/stream'
        response.headers = {'Location': 'http://127.0.0.1/secret'}
        with self.assertRaises(ValueError):
            sources._get(session, response.url, sources.time.monotonic() + 10)
        self.assertEqual(session.get.call_count, 1)
        self.assertFalse(sources._allowed_url('https://attacker.r2.cloudflarestorage.com/song'))
        self.assertTrue(sources._allowed_url('https://' + sources.STORAGE_HOST + '/song'))
        response.close.assert_called_once()

    def test_negative_cache_and_ambiguous_recordings(self):
        response = MagicMock()
        response.__enter__.return_value = response
        response.iter_content.return_value = [json.dumps({'data': [TRACK, dict(TRACK, id='Other')]}).encode()]
        with tempfile.TemporaryDirectory() as folder, patch.object(sources, '_get', return_value=response) as get:
            self.assertIsNone(sources.recover(ID, folder))
            self.assertIsNone(sources.recover(ID, folder))
            self.assertEqual(get.call_count, 1)
            self.assertEqual(list(Path(folder).iterdir()), [])

    def test_success_returns_same_file_contract_and_cleans_source(self):
        metadata, stream = MagicMock(), MagicMock()
        for response in (metadata, stream):
            response.__enter__.return_value = response
        metadata.iter_content.return_value = [json.dumps({'data': [TRACK]}).encode()]
        stream.headers = {'Content-Type': 'audio/mpeg'}
        stream.iter_content.return_value = [b'audio']
        def convert(source, output, duration):
            self.assertEqual(source.read_bytes(), b'audio')
            output.write_bytes(b'm4a')
        with tempfile.TemporaryDirectory() as folder, patch.object(sources, '_get', side_effect=[metadata, stream]), patch.object(sources, '_convert', side_effect=convert):
            result = sources.recover(ID, folder)
            self.assertEqual(result, (Path(folder) / 'alternative.m4a', 'Song', None))
            self.assertFalse((Path(folder) / 'alternative.audio').exists())

    @unittest.skipUnless(shutil.which("ffmpeg") and shutil.which("ffprobe"), "requires ffmpeg")
    def test_real_conversion_rejects_preview_and_produces_m4a(self):
        import subprocess
        with tempfile.TemporaryDirectory() as folder:
            source, output = Path(folder) / 'tone.wav', Path(folder) / 'tone.m4a'
            subprocess.run(['ffmpeg', '-v', 'error', '-f', 'lavfi', '-i',
                            'sine=frequency=440:duration=3', str(source)], check=True)
            with self.assertRaises(ValueError):
                sources._convert(source, output, 180)
            sources._convert(source, output, 3)
            self.assertGreater(output.stat().st_size, 1024)

    def test_worker_recovers_during_youtube_cooldown(self):
        main._pause_youtube_requests()
        with patch.object(main, '_extract_m4a') as primary, patch.object(sources, 'recover', return_value=(Path('song.m4a'), 'Song', None)) as fallback:
            result = main._run_extraction('https://youtube.com/watch?v=' + ID)
            self.addCleanup(shutil.rmtree, result[3], True)
            self.assertEqual(result[:3], (Path('song.m4a'), 'Song', None))
            primary.assert_not_called()
            fallback.assert_called_once()

    def test_failed_recovery_preserves_original_error(self):
        error = HTTPException(503, 'unavailable', headers={'Retry-After': '300'})
        with patch.object(main, '_extract_m4a', side_effect=error), patch.object(sources, 'recover', return_value=None):
            with self.assertRaises(HTTPException) as caught:
                main._run_extraction('https://youtube.com/watch?v=' + ID)
            self.assertIs(caught.exception, error)

    def test_permanent_error_does_not_substitute(self):
        with patch.object(main, '_extract_m4a', side_effect=HTTPException(413, 'too long')), patch.object(sources, 'recover') as fallback:
            with self.assertRaises(HTTPException):
                main._run_extraction('https://youtube.com/watch?v=' + ID)
            fallback.assert_not_called()


class SearchResilienceTests(unittest.TestCase):
    def setUp(self):
        search._search_cache.clear()
        search._stale.clear()

    def test_identical_concurrent_requests_use_one_provider_call(self):
        entered, release = threading.Event(), threading.Event()
        def fetch():
            entered.set()
            self.assertTrue(release.wait(3))
            return ['same']
        with patch.object(search, 'Future', wraps=search.Future) as future, ThreadPoolExecutor(2) as pool:
            a = pool.submit(search._cached_call, 'search', 'key', search._search_cache, fetch)
            self.assertTrue(entered.wait(3))
            b = pool.submit(search._cached_call, 'search', 'key', search._search_cache, fetch)
            release.set()
            self.assertEqual(a.result(3), b.result(3))
            self.assertEqual(future.call_count, 1)
        self.assertEqual(search._pending, {})

    def test_outage_serves_recent_result_without_renewing_stale_cache(self):
        search._cached_call('search', 'key', search._search_cache, lambda: ['recent'])
        search._search_cache.clear()
        def fail():
            raise ConnectionError()
        self.assertEqual(search._cached_call('search', 'key', search._search_cache, fail), ['recent'])
        self.assertNotIn('key', search._search_cache)
        search._stale.clear()
        with self.assertRaises(HTTPException) as caught:
            search._cached_call('search', 'key', search._search_cache, fail)
        self.assertEqual(caught.exception.status_code, 502)
        self.assertEqual(search._pending, {})
