"""Dev Demucs gate tests; no weights, GPU or network required."""
import os
import unittest
from unittest.mock import patch
from fastapi.testclient import TestClient
import main


class Stage41DevStemSecurityTests(unittest.TestCase):
    def setUp(self):
        self.client = TestClient(main.app)

    def test_endpoint_disabled_by_default(self):
        with patch.dict(os.environ, {"STEMS_DEV_ENABLED": "0", "STEMS_DEV_TOKEN": "secret-" * 4}):
            response = self.client.post("/api/stems", content=b"some audio",
                                        headers={"Content-Type": "application/octet-stream"})
            self.assertEqual(response.status_code, 404)

    def test_enabled_endpoint_requires_matching_secret(self):
        with patch.dict(os.environ, {"STEMS_DEV_ENABLED": "1", "STEMS_DEV_TOKEN": "secret-" * 4}):
            response = self.client.post("/api/stems", content=b"some audio",
                                        headers={"Content-Type": "application/octet-stream"})
            self.assertEqual(response.status_code, 401)

    def test_protected_endpoint_rejects_empty_payload(self):
        secret = "secret-" * 4
        with patch.dict(os.environ, {"STEMS_DEV_ENABLED": "1", "STEMS_DEV_TOKEN": secret}):
            response = self.client.post("/api/stems", content=b"",
                headers={"Content-Type": "application/octet-stream",
                         "Authorization": "Bearer " + secret})
            self.assertEqual(response.status_code, 400)

    def test_rejects_large_payload_before_creating_job(self):
        secret = "secret-" * 4
        with patch.dict(os.environ, {"STEMS_DEV_ENABLED": "1", "STEMS_DEV_TOKEN": secret}):
            response = self.client.post("/api/stems", content=b"x",
                headers={"Content-Type": "application/octet-stream",
                         "Content-Length": str(35 * 1024 * 1024 + 1),
                         "Authorization": "Bearer " + secret})
            self.assertEqual(response.status_code, 413)


if __name__ == "__main__":
    unittest.main()
