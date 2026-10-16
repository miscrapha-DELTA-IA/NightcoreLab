"""Contract checks for the isolated HTDemucs dev worker (no model download)."""
import os
import unittest
from pathlib import Path
from unittest.mock import patch

from fastapi.testclient import TestClient
from demucs_app import app


class DemucsDevIsolatedAppTests(unittest.TestCase):
    def setUp(self):
        self.client = TestClient(app)

    def test_windows_launcher_tries_python315_before_isolated_311_fallback(self):
        root = Path(__file__).resolve().parent.parent
        script = (root / "scripts" / "dev-stems" /
                  "start-demucs-windows.ps1").read_text(encoding="utf-8")
        profile = (root / "backend" /
                   "requirements-demucs-dev-315.txt").read_text(encoding="utf-8")
        self.assertIn('@("3.15", "3.11")', script)
        self.assertIn('py install 3.11', script)
        self.assertIn('https://download.pytorch.org/whl/nightly/cpu', script)
        self.assertIn('if (-not (Test-Demucs $interpreter))', script)
        self.assertIn('demucs==4.1.0', profile)

    def test_health_reports_isolated_worker(self):
        with patch.dict(os.environ, {"STEMS_DEV_ENABLED": "1"}):
            reply = self.client.get("/health")
            self.assertEqual(reply.status_code, 200)
            self.assertEqual(reply.json()["service"], "nightcorelab-demucs-dev")
            self.assertEqual(reply.json()["model"], "htdemucs")
            self.assertTrue(reply.json()["enabled"])

    def test_upload_requires_authentication(self):
        with patch.dict(os.environ, {
            "STEMS_DEV_ENABLED": "1", "STEMS_DEV_TOKEN": "secret-0123456789012345"
        }):
            reply = self.client.post(
                "/api/stems", content=b"some audio",
                headers={"Content-Type": "application/octet-stream"})
            self.assertEqual(reply.status_code, 401)

    def test_disabled_dev_endpoint_stays_inaccessible(self):
        with patch.dict(os.environ, {
            "STEMS_DEV_ENABLED": "0", "STEMS_DEV_TOKEN": "secret-0123456789012345"
        }):
            reply = self.client.post(
                "/api/stems", content=b"some audio",
                headers={"Content-Type": "application/octet-stream"})
            self.assertEqual(reply.status_code, 404)


if __name__ == "__main__":
    unittest.main()
