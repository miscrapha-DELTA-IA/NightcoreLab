"""Fast, offline regression coverage for on-disk audio cache."""
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

import main


class AudioCacheTests(unittest.TestCase):
    def setUp(self):
        self.folder = tempfile.TemporaryDirectory()
        self.addCleanup(self.folder.cleanup)
        self.cache_patch = patch.object(main, "CACHE_DIR", Path(self.folder.name) / "cache")
        self.cache_patch.start()
        self.addCleanup(self.cache_patch.stop)
        main._cache_readers.clear()

    def _seed(self, video_id, data, title="Song"):
        main.CACHE_DIR.mkdir(parents=True, exist_ok=True)
        source = Path(self.folder.name) / f"{video_id}.m4a"
        source.write_bytes(data)
        workspace = Path(self.folder.name) / "work"
        workspace.mkdir(exist_ok=True)
        return main._cache_extracted_audio(video_id, (source, title, None, str(workspace)))

    def test_cache_hit_and_metadata(self):
        self._seed("abcdefghijk", b"abc", "Test song")
        cached = main._cached_audio("abcdefghijk")
        self.assertIsNotNone(cached)
        self.assertEqual(cached[1], "Test song")
        self.assertEqual(cached[0].read_bytes(), b"abc")

    def test_lru_preserves_active_reader(self):
        with patch.object(main, "MAX_CACHE_BYTES", 5):
            self._seed("aaaaaaaaaaa", b"1234")
            main._pin_cached_audio("aaaaaaaaaaa")
            self._seed("bbbbbbbbbbb", b"5678")
            main._prune_audio_cache()
            self.assertTrue((main.CACHE_DIR / "aaaaaaaaaaa.m4a").exists())
            self.assertFalse((main.CACHE_DIR / "bbbbbbbbbbb.m4a").exists())
            main._release_cached_reader("aaaaaaaaaaa")

    def test_missing_metadata_is_not_cache_hit(self):
        main.CACHE_DIR.mkdir(parents=True, exist_ok=True)
        (main.CACHE_DIR / "ccccccccccc.m4a").write_bytes(b"abc")
        self.assertIsNone(main._cached_audio("ccccccccccc"))


if __name__ == "__main__":
    unittest.main()
