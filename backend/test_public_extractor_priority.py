"""Public-track extractor ordering without touching the network."""
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

import yt_dlp
import main


class PublicStrategyOrderTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.url = "https://www.youtube.com/watch?v=ABCDEFGHIJK"
        with main._youtube_cooldown_lock:
            self.old_cooldown = main._youtube_cooldown_until
            main._youtube_cooldown_until = 0

    def tearDown(self):
        with main._youtube_cooldown_lock:
            main._youtube_cooldown_until = self.old_cooldown
        self.temp.cleanup()

    def test_public_recording_uses_unauthenticated_session_first_even_with_cookies(self):
        extracted = (Path(self.temp.name) / "ABCDEFGHIJK.m4a", "Same Recording", None)
        with patch.object(main, "COOKIES_FILE", "/etc/secrets/COOKIES_FILE"), \
             patch.object(main.os.path, "isfile", return_value=True), \
             patch.object(main, "_cookies_summary", return_value={
                 "entries": 23, "youtube_domain": True,
                 "logged_in": True, "netscape_header": True, "login_cookies": []}), \
             patch.object(main, "_strategy_available", return_value=True), \
             patch.object(main, "_extract_with", return_value=extracted) as extractor:
            result = main._extract_m4a(self.url, self.temp.name)
        self.assertEqual(result, extracted)
        self.assertEqual(extractor.call_count, 1)
        args = extractor.call_args.args
        self.assertEqual(args[2], "anônimo/padrão")
        self.assertIs(args[3], False)
        self.assertIsNone(args[4])

    def test_real_rate_limit_does_not_cycle_five_accounts_or_clients(self):
        with patch.object(main, "COOKIES_FILE", "/etc/secrets/COOKIES_FILE"), \
             patch.object(main.os.path, "isfile", return_value=True), \
             patch.object(main, "_cookies_summary", return_value={
                 "entries": 23, "youtube_domain": True,
                 "logged_in": True, "netscape_header": True, "login_cookies": []}), \
             patch.object(main, "_strategy_available", return_value=True), \
             patch.object(main, "_extract_with", side_effect=yt_dlp.utils.DownloadError(
                 "HTTP Error 429: Too Many Requests")) as extractor:
            with self.assertRaises(Exception):
                main._extract_m4a(self.url, self.temp.name)
        self.assertEqual(extractor.call_count, 1)


if __name__ == "__main__":
    unittest.main()
