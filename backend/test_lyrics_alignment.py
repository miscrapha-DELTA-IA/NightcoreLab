"""Offline coverage for Whisper parameters, source matching and endpoint cleanup."""

import asyncio
from pathlib import Path
from tempfile import TemporaryDirectory
from threading import Event
from types import SimpleNamespace
import unittest
from unittest.mock import patch

from fastapi import HTTPException

import lyrics_alignment
import main


class LyricsAlignmentTests(unittest.TestCase):
    def test_enhanced_lrc_preserves_source_lines_and_final_word_end(self):
        words = [SimpleNamespace(word=text, start=start, end=end) for text, start, end in [
            ("palavra", 12.0, 12.4), ("seguinte", 12.5, 13.2),
            ("outra", 15.0, 15.4), ("linha", 15.5, 16.0),
        ]]
        lrc = lyrics_alignment._enhanced_lrc("Palavra seguinte\nOutra linha", words)
        self.assertEqual(lrc, "[00:12.00] <00:12.00> Palavra <00:12.40> <00:12.50> seguinte <00:13.20>\n"
                              "[00:15.00] <00:15.00> Outra <00:15.40> <00:15.50> linha <00:16.00>")

    def test_does_not_present_hallucinated_transcription_as_source_lyrics(self):
        words = [SimpleNamespace(word="inventada", start=1.0, end=1.5)]
        with self.assertRaises(lyrics_alignment.AlignmentError):
            lyrics_alignment._enhanced_lrc("Palavra seguinte", words)

    def test_partial_line_keeps_all_source_words_without_fake_word_timing(self):
        words = [SimpleNamespace(word=text, start=start, end=end) for text, start, end in [
            ("a", 1.0, 1.2), ("canção", 1.5, 1.8), ("continua", 2.0, 2.3),
            ("agora", 3.0, 3.3), ("sim", 3.5, 3.8),
        ]]
        lrc = lyrics_alignment._enhanced_lrc("A bela canção continua\nAgora sim", words)
        self.assertEqual(lrc.splitlines()[0], "[00:01.00] A bela canção continua")
        self.assertIn("<00:03.00> Agora", lrc.splitlines()[1])

    def test_rejects_an_entire_unmatched_line(self):
        words = [SimpleNamespace(word=text, start=float(i), end=float(i) + 0.2)
                 for i, text in enumerate("um dois três quatro cinco seis sete oito nove dez".split())]
        lyrics = "Um dois três quatro cinco\nVerso ausente\nSeis sete oito nove dez"
        with self.assertRaises(lyrics_alignment.AlignmentError):
            lyrics_alignment._enhanced_lrc(lyrics, words)

    def test_whisper_request_uses_required_word_parameters_and_plain_prompt(self):
        with TemporaryDirectory() as folder:
            audio = Path(folder) / "song.m4a"
            audio.write_bytes(b"audio")
            words = [SimpleNamespace(word="Olá", start=1.0, end=1.5)]
            with patch.object(lyrics_alignment, "OpenAI") as client:
                client.return_value.audio.transcriptions.create.return_value.words = words
                result = lyrics_alignment.generate_enhanced_lrc(audio, "Olá")
                self.assertEqual(result, "[00:01.00] <00:01.00> Olá <00:01.50>")
                kwargs = client.return_value.audio.transcriptions.create.call_args.kwargs
                self.assertEqual(kwargs["model"], "whisper-1")
                self.assertEqual(kwargs["response_format"], "verbose_json")
                self.assertEqual(kwargs["timestamp_granularities"], ["word"])
                self.assertEqual(kwargs["prompt"], "Olá")


class AlignLyricsEndpointTests(unittest.IsolatedAsyncioTestCase):
    async def test_releases_audio_after_transcription(self):
        released = []

        async def fake_download(_request, background_tasks):
            background_tasks.add_task(lambda: released.append(True))
            return SimpleNamespace(path="song.m4a")

        with patch.dict(main.os.environ, {"OPENAI_API_KEY": "test"}), \
             patch.object(main, "download", fake_download), \
             patch.object(main, "generate_enhanced_lrc", return_value="[00:01.00] <00:01.00> Olá"):
            result = await main.align_lyrics(main.AlignLyricsRequest(
                url="https://www.youtube.com/watch?v=abcdefghijk", lyrics="Olá"))
        self.assertEqual(result["lrc"], "[00:01.00] <00:01.00> Olá")
        self.assertEqual(released, [True])

    async def test_releases_audio_when_alignment_is_rejected(self):
        released = []

        async def fake_download(_request, background_tasks):
            background_tasks.add_task(lambda: released.append(True))
            return SimpleNamespace(path="song.m4a")

        with patch.dict(main.os.environ, {"OPENAI_API_KEY": "test"}), \
             patch.object(main, "download", fake_download), \
             patch.object(main, "generate_enhanced_lrc",
                          side_effect=lyrics_alignment.AlignmentError("divergente")):
            with self.assertRaises(HTTPException) as raised:
                await main.align_lyrics(main.AlignLyricsRequest(
                    url="https://www.youtube.com/watch?v=abcdefghijk", lyrics="Olá"))
        self.assertEqual(raised.exception.status_code, 422)
        self.assertEqual(released, [True])

    async def test_disconnect_keeps_audio_pinned_until_transcription_stops(self):
        started, finish = Event(), Event()
        released = []

        async def fake_download(_request, background_tasks):
            background_tasks.add_task(lambda: released.append(True))
            return SimpleNamespace(path="song.m4a")

        def slow_alignment(_path, _lyrics):
            started.set()
            finish.wait(timeout=2)
            return "aligned"

        with patch.dict(main.os.environ, {"OPENAI_API_KEY": "test"}), \
             patch.object(main, "download", fake_download), \
             patch.object(main, "generate_enhanced_lrc", slow_alignment):
            task = asyncio.create_task(main.align_lyrics(main.AlignLyricsRequest(
                url="https://www.youtube.com/watch?v=abcdefghijk", lyrics="Olá")))
            await asyncio.to_thread(started.wait, 2)
            task.cancel()
            await asyncio.sleep(0)
            self.assertEqual(released, [])
            finish.set()
            with self.assertRaises(asyncio.CancelledError):
                await task
        self.assertEqual(released, [True])


if __name__ == "__main__":
    unittest.main()
