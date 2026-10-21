"""Admission, quotas and signed audio binding without GPU/network access."""
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

from fastapi.testclient import TestClient
import main
from zerogpu_space.tickets import issue, verify


class FreeCloudStemTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.secret = "signing-" * 8
        self.code = "beta-access-" * 3
        self.url = "https://raphael-deltaia-gnarly-free-stems.hf.space"
        self.env = {"STEMS_CLOUD_ENABLED": "1", "STEMS_CLOUD_FREE_ONLY": "1",
                    "STEMS_CLOUD_SPACE_URL": self.url, "STEMS_CLOUD_SIGNING_KEY": self.secret,
                    "STEMS_CLOUD_BETA_CODE": self.code, "STEMS_CLOUD_DAILY_JOBS": "2",
                    "STEMS_CLOUD_BUDGET_DB": str(Path(self.directory.name) / "budget.sqlite3")}
        self.patch = patch.dict(os.environ, self.env)
        self.patch.start()
        self.addCleanup(self.patch.stop)
        self.health = patch("cloud_stems._community_runtime_ready", return_value=True)
        self.health.start()
        self.addCleanup(self.health.stop)
        self.client = TestClient(main.app)
        self.body = {"sha256": "a" * 64, "bytes": 1234, "seconds": 293}

    def request(self, **updates):
        return self.client.post("/v1/stems/cloud/ticket", json={**self.body, **updates},
                                headers={"Authorization": "Bearer " + self.code})

    def test_disabled_until_explicitly_configured(self):
        with patch.dict(os.environ, {"STEMS_CLOUD_ENABLED": "0"}):
            self.assertFalse(self.client.get("/v1/stems/cloud").json()["enabled"])
            self.assertEqual(self.request().status_code, 503)

    def test_invalid_configuration_fails_closed(self):
        for env in ({"STEMS_CLOUD_FREE_ONLY": "0"}, {"STEMS_CLOUD_SIGNING_KEY": "short"},
                    {"STEMS_CLOUD_SPACE_URL": "https://replicate.com"},
                    {"STEMS_CLOUD_SPACE_URL": "https://evil.hf.space.attacker.test"},
                    {"STEMS_CLOUD_SPACE_URL": "http://test.hf.space"}):
            with self.subTest(env=env), patch.dict(os.environ, env):
                self.assertEqual(self.request().status_code, 503)

    def test_requires_beta_code(self):
        self.assertEqual(self.client.post("/v1/stems/cloud/ticket", json=self.body).status_code, 401)

    def test_audio_limits_before_authorization(self):
        for updates in ({"bytes": 35 * 1024 * 1024 + 1}, {"seconds": 600},
                        {"seconds": -1}, {"sha256": "not-a-hash"}):
            with self.subTest(updates=updates):
                self.assertEqual(self.request(**updates).status_code, 422)

    def test_ticket_binds_origin_audio_and_duration(self):
        with patch("cloud_stems.time.time", return_value=1000):
            response = self.request()
        self.assertEqual(response.status_code, 200, response.text)
        result = response.json()
        claims = verify(self.secret, result["ticket"], self.url, now=1001)
        for key in self.body:
            self.assertEqual(claims[key], self.body[key])
        self.assertEqual(result["space_url"], self.url)
        self.assertEqual(result["max_gpu_seconds"], 120)
        self.assertNotIn(self.secret, response.text)
        self.assertNotIn(self.code, response.text)
        for ticket, audience, now in ((result["ticket"] + "x", self.url, 1001),
                                     (result["ticket"], self.url + "wrong", 1001),
                                     (result["ticket"], self.url, 1901)):
            with self.assertRaises(ValueError):
                verify(self.secret, ticket, audience, now=now)

    def test_serial_admission_and_rolling_daily_hard_cap(self):
        with patch("cloud_stems.time.time", return_value=1000):
            self.assertEqual(self.request().status_code, 200)
            self.assertEqual(self.request().status_code, 429)
        with patch("cloud_stems.time.time", return_value=2000):
            self.assertEqual(self.request().status_code, 200)
        with patch("cloud_stems.time.time", return_value=4000), \
             patch.dict(os.environ, {"STEMS_CLOUD_DAILY_JOBS": "99999"}):
            self.assertEqual(self.request().status_code, 429)
        with patch("cloud_stems.time.time", return_value=88401):
            self.assertEqual(self.request().status_code, 200)

    def test_budget_database_error_blocks_instead_of_bypassing(self):
        with patch.dict(os.environ, {"STEMS_CLOUD_BUDGET_DB": "/no-such-directory/budget.db"}):
            self.assertEqual(self.request().status_code, 503)

    def test_signed_malformed_payloads_do_not_authorize(self):
        for payload in ([], {}, {"aud": self.url}, {"exp": "tomorrow"}):
            with self.assertRaises(ValueError):
                verify(self.secret, issue(self.secret, payload), self.url, now=1000)

    def test_community_profile_needs_no_account_secret_or_beta_code(self):
        from cloud_stems import COMMUNITY_URL, COMMUNITY_MODEL
        with patch.dict(os.environ, {"STEMS_CLOUD_PROVIDER": "community_bs_roformer",
                "STEMS_CLOUD_SPACE_URL": COMMUNITY_URL, "STEMS_CLOUD_SIGNING_KEY": "",
                "STEMS_CLOUD_BETA_CODE": ""}):
            config = self.client.get("/v1/stems/cloud").json()
            self.assertTrue(config["enabled"])
            self.assertTrue(config["provider_available"])
            self.assertFalse(config["requires_beta_code"])
            response = self.client.post("/v1/stems/cloud/ticket", json=self.body)
            self.assertEqual(response.status_code, 200)
            self.assertEqual(response.json()["model"], COMMUNITY_MODEL)
            self.assertEqual(response.json()["space_url"], COMMUNITY_URL)
            self.assertEqual(response.json()["provider"], "community_bs_roformer")
            self.assertEqual(self.request().status_code, 429)

    def test_community_profile_cannot_be_retargeted_or_use_paid_mode(self):
        for url in (self.url, "https://replicate.com"):
            with patch.dict(os.environ, {"STEMS_CLOUD_PROVIDER": "community_bs_roformer",
                    "STEMS_CLOUD_SPACE_URL": url}):
                self.assertEqual(self.request().status_code, 503)
        with patch.dict(os.environ, {"STEMS_CLOUD_PROVIDER": "unknown"}):
            self.assertEqual(self.request().status_code, 503)

    def test_community_optional_private_beta_code_remains_enforced(self):
        from cloud_stems import COMMUNITY_URL
        with patch.dict(os.environ, {"STEMS_CLOUD_PROVIDER": "community_bs_roformer",
                "STEMS_CLOUD_SPACE_URL": COMMUNITY_URL}):
            self.assertTrue(self.client.get("/v1/stems/cloud").json()["requires_beta_code"])
            self.assertEqual(self.client.post("/v1/stems/cloud/ticket", json=self.body).status_code, 401)
            self.assertEqual(self.request().status_code, 200)

    def test_changed_or_offline_community_app_does_not_consume_admission(self):
        from cloud_stems import COMMUNITY_URL
        with patch.dict(os.environ, {"STEMS_CLOUD_PROVIDER": "community_bs_roformer",
                "STEMS_CLOUD_SPACE_URL": COMMUNITY_URL}), \
             patch("cloud_stems._community_runtime_ready", return_value=False):
            self.assertFalse(self.client.get("/v1/stems/cloud").json()["provider_available"])
            self.assertEqual(self.request().status_code, 503)
        with patch.dict(os.environ, {"STEMS_CLOUD_PROVIDER": "community_bs_roformer",
                "STEMS_CLOUD_SPACE_URL": COMMUNITY_URL}):
            self.assertEqual(self.request().status_code, 200)


if __name__ == "__main__":
    unittest.main()
