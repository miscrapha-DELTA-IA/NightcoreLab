"""Offline contracts for YT Music metadata API (no live YouTube calls)."""
import unittest
from unittest.mock import patch, MagicMock
from fastapi.testclient import TestClient
import main
import backend_search

class MetadataSearchTests(unittest.TestCase):
    def setUp(self):
        self.client = TestClient(main.app)
        backend_search._search_cache.clear()
        backend_search._suggest_cache.clear()

    def test_structured_hit_and_cache(self):
        mock = MagicMock()
        mock.search.return_value = [
            {"videoId": "abcdefghijk", "title": "Sample Song",
             "artists": [{"name": "Artist One"}], "album": {"name": "Album"},
             "duration_seconds": 183, "thumbnails": [{"url": "https://example.org/cover.jpg"}]}]
        with patch.object(backend_search, "YTMusic", return_value=mock):
            a = self.client.get("/v1/search", params={"q": "sample", "limit": 3})
            b = self.client.get("/v1/search", params={"q": "sample", "limit": 3})
        self.assertEqual(a.status_code, 200)
        self.assertEqual(a.json()[0]["artist"], "Artist One")
        self.assertEqual(a.json()[0]["duration"], 183)
        self.assertEqual(a.json()[0]["isSong"], True)
        self.assertEqual(b.json(), a.json())
        self.assertEqual(mock.search.call_count, 2)  # songs + fallback videos, once per cache key

    def test_deduplicates_video_fallback(self):
        mock = MagicMock()
        song = {"videoId": "abcdefghijk", "title": "Song"}
        video = {"videoId": "lmnopqrstuv", "title": "Other"}
        mock.search.side_effect = [[song], [song, video]]
        with patch.object(backend_search, "YTMusic", return_value=mock):
            res = self.client.get("/v1/search", params={"q": "song"})
        self.assertEqual([x["id"] for x in res.json()], ["abcdefghijk", "lmnopqrstuv"])

    def test_suggestions(self):
        mock = MagicMock()
        mock.get_search_suggestions.return_value = ["one", "two"]
        with patch.object(backend_search, "YTMusic", return_value=mock):
            res = self.client.get("/v1/suggest", params={"q": "on"})
        self.assertEqual(res.json(), ["one", "two"])

    def test_invalid_query(self):
        self.assertEqual(self.client.get("/v1/search", params={"q": "x"}).status_code, 422)
        self.assertEqual(self.client.get("/v1/search", params={"q": "x"*121}).status_code, 422)

if __name__ == "__main__":
    unittest.main()
