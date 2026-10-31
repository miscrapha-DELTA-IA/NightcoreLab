"""Offline contract tests for independent same-video parser and process isolation."""
import contextlib
import io
import json
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest
from unittest.mock import patch

import alternate_extractor as alt
import main
import yt_dlp


ID = "ABCDEFGHIJK"
M4A = b"\x00\x00\x00\x18ftypM4A " + b"\x00" * 2048


class AlternateExtractionTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="gnarly-alternate-test-")

    def tearDown(self):
        shutil.rmtree(self.tmp, ignore_errors=True)

    def test_only_format_failures_qualify(self):
        self.assertTrue(alt.should_attempt(yt_dlp.utils.DownloadError(
            "ERROR: Requested format is not available")))
        self.assertTrue(alt.should_attempt(yt_dlp.utils.DownloadError(
            "Failed to extract any player response")))
        for error in (
            yt_dlp.utils.DownloadError("HTTP Error 429 Too Many Requests"),
            yt_dlp.utils.DownloadError("HTTP Error 403 Forbidden"),
            yt_dlp.utils.DownloadError("Sign in to confirm you are not a bot"),
            yt_dlp.utils.DownloadError("This is a private video"),
        ):
            self.assertFalse(alt.should_attempt(error))
        with patch.dict("os.environ", {"GNARLY_ALTERNATE_EXTRACTOR": "0"}):
            self.assertFalse(alt.should_attempt(yt_dlp.utils.DownloadError(
                "Requested format is not available")))

    def test_output_requires_exact_requested_id_and_mp4_signature(self):
        path = Path(self.tmp) / f"{ID}.m4a"
        path.write_bytes(M4A)
        self.assertTrue(alt._valid_output(path, Path(self.tmp), ID))
        path.write_bytes(b"<html>" + b" " * 2048)
        self.assertFalse(alt._valid_output(path, Path(self.tmp), ID))
        self.assertFalse(alt._valid_output(Path(self.tmp) / "wrong.m4a", Path(self.tmp), ID))

    def test_process_fallback_does_not_log_secrets_or_return_fake_audio(self):
        path = Path(self.tmp) / f"{ID}.m4a"
        path.write_bytes(M4A)
        good = subprocess.CompletedProcess([], 0, json.dumps({
            "title": "Same Recording", "thumbnail": "https://example.com/cover.jpg"}), "")
        with patch.object(alt.subprocess, "run", return_value=good) as run:
            result = alt.extract(ID, self.tmp)
        self.assertEqual(result[0], path)
        self.assertEqual(result[1], "Same Recording")
        args, kwargs = run.call_args
        self.assertNotIn("shell", kwargs)
        self.assertEqual(kwargs["timeout"], 36)
        self.assertEqual(args[0][2], "alternate_extractor")
        self.assertEqual(args[0][4], ID)
        self.assertEqual(args[0][5], self.tmp)
        self.assertNotIn("cookie", str(args[0]).lower())
        with patch.object(alt.subprocess, "run",
                          return_value=subprocess.CompletedProcess([], 0, "<html>", "")):
            self.assertIsNone(alt.extract(ID, self.tmp))

    def test_child_timeout_is_bounded_without_failing_parent(self):
        with patch.object(alt.subprocess, "run",
                          side_effect=subprocess.TimeoutExpired("extractor", 36)):
            self.assertIsNone(alt.extract(ID, self.tmp))
        self.assertIsNone(alt.extract("../../fake", self.tmp))

    def test_worker_same_recording_and_duration_limit(self):
        class Track:
            filesize = 2048
            def download(self, **opts):
                target = Path(opts["output_path"]) / opts["filename"]
                target.write_bytes(M4A)
                return str(target)
        class Streams:
            def get_audio_only(self, **opts):
                self.opts = opts
                return Track()
        class Video:
            title = "Original"
            thumbnail_url = "https://example.com/art.jpg"
            length = 120
            streams = Streams()
        calls = []
        def factory(*args, **kwargs):
            calls.append((args, kwargs))
            return Video()
        output = io.StringIO()
        with contextlib.redirect_stdout(output):
            status = alt.run_worker(ID, self.tmp, factory)
        self.assertEqual(status, 0)
        self.assertEqual(json.loads(output.getvalue())["title"], "Original")
        self.assertEqual(calls[0][0][0], f"https://www.youtube.com/watch?v={ID}")
        self.assertFalse(calls[0][1]["use_oauth"])
        self.assertEqual(Video.streams.opts["subtype"], "mp4")

        class TooLong(Video):
            length = 600
        self.assertEqual(alt.run_worker(ID, self.tmp, lambda *a, **k: TooLong()), 3)

    def test_main_integrates_only_after_recoverable_format_failure(self):
        expected = (Path(self.tmp) / f"{ID}.m4a", "Same Recording", None)
        with patch.object(main, "_sweep_stale_work_dirs"), \
             patch.object(main, "_check_youtube_cooldown"), \
             patch.object(main, "_extract_m4a",
                          side_effect=yt_dlp.utils.DownloadError("Requested format is not available")), \
             patch.object(main.alternate_extractor, "extract", return_value=expected) as secondary, \
             patch.object(main.audio_sources, "recover",
                          side_effect=AssertionError("Unneeded unrelated provider")):
            result = main._run_extraction(f"https://www.youtube.com/watch?v={ID}")
        self.assertEqual(result[1], "Same Recording")
        self.assertTrue(secondary.called)
        shutil.rmtree(result[-1], ignore_errors=True)

    def test_main_never_retries_alternate_parser_on_known_429(self):
        with patch.object(main, "_sweep_stale_work_dirs"), \
             patch.object(main, "_extract_m4a",
                          side_effect=yt_dlp.utils.DownloadError("HTTP Error 429 Too Many Requests")), \
             patch.object(main.alternate_extractor, "extract",
                          side_effect=AssertionError("Must not retry provider 429")), \
             patch.object(main.audio_sources, "recover",
                          side_effect=AssertionError("Must not substitute recording")):
            with self.assertRaises(yt_dlp.utils.DownloadError):
                main._run_extraction(f"https://www.youtube.com/watch?v={ID}")


if __name__ == "__main__":
    unittest.main()
