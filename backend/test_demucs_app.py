"""Contract checks for the isolated HTDemucs dev worker (no model download)."""
import os
import subprocess
import tempfile
import time
import unittest
from pathlib import Path
from unittest.mock import patch

from fastapi.testclient import TestClient
from demucs_app import app
import stems_dev


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

    def test_worker_has_bounded_cpu_profile_and_35min_default(self):
        with patch.dict(os.environ, {
            "STEMS_DEV_MODEL": "htdemucs",
            "STEMS_DEV_TIMEOUT_SECONDS": "2100",
        }):
            self.assertEqual(stems_dev._timeout_seconds(), 2100)
            command = stems_dev._demucs_command(Path("temp"), Path("temp/source.m4a"))
            self.assertIn("htdemucs", command)
            self.assertEqual(command[command.index("--overlap") + 1], "0.1")
            self.assertEqual(command[command.index("--shifts") + 1], "0")
            self.assertEqual(command[command.index("--segment") + 1], "7")
            self.assertEqual(command[command.index("-j") + 1], "1")

    def test_compact_model_is_explicit_and_configurable(self):
        with patch.dict(os.environ, {
            "STEMS_DEV_MODEL": "mdx_q",
            "STEMS_DEV_TIMEOUT_SECONDS": "2100",
        }):
            health = self.client.get("/health").json()
            self.assertEqual(health["model"], "mdx_q")
            self.assertEqual(health["timeout_seconds"], 2100)
            command = stems_dev._demucs_command(Path("temp"), Path("temp/source.m4a"))
            self.assertIn("mdx_q", command)

    def test_timeout_has_distinct_message_and_keeps_local_log(self):
        with tempfile.TemporaryDirectory(prefix="nightcore-demucs-test-") as directory:
            folder = Path(directory)
            job_id = "testdeadlinedemucs"
            job = dict(id=job_id, folder=str(folder), status="processing",
                       model="htdemucs", timeout_seconds=2100,
                       created=time.monotonic(), message=None)
            with patch.dict(stems_dev._jobs, {job_id: job}, clear=True), \
                    patch("stems_dev.subprocess.run", side_effect=subprocess.TimeoutExpired(
                        cmd="demucs", timeout=2100)):
                stems_dev._process(job_id)
            self.assertEqual(job["status"], "failed")
            self.assertIn("35 minutos", job["message"])
            self.assertTrue((folder / "demucs.log").is_file())

    def test_failed_exit_is_not_misreported_as_timeout(self):
        with tempfile.TemporaryDirectory(prefix="nightcore-demucs-test-") as directory:
            folder = Path(directory)
            job_id = "testfailurecode"
            job = dict(id=job_id, folder=str(folder), status="processing",
                       model="htdemucs", timeout_seconds=2100,
                       created=time.monotonic(), message=None)
            with patch.dict(stems_dev._jobs, {job_id: job}, clear=True), \
                    patch("stems_dev.subprocess.run", return_value=subprocess.CompletedProcess(
                        args=["demucs"], returncode=7)):
                stems_dev._process(job_id)
            self.assertEqual(job["status"], "failed")
            self.assertIn("código 7", job["message"])
            self.assertNotIn("excedeu", job["message"])

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
