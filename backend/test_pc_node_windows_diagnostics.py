"""Regression: Windows worker diagnostics never expose tokens and retry only transient faults."""
import importlib.util
from pathlib import Path
import socket
import unittest
from unittest.mock import patch
from urllib.error import HTTPError, URLError


MODULE = Path(__file__).resolve().parents[1] / "pc-node" / "agent.py"
spec = importlib.util.spec_from_file_location("pc_node_agent_test", MODULE)
agent = importlib.util.module_from_spec(spec)
spec.loader.exec_module(agent)


class WindowsNodeDiagnosticsTests(unittest.TestCase):
    def test_http_diagnostics_are_classified_without_body_or_token(self):
        cases = ((401, False), (403, False), (404, False), (429, True), (503, True))
        for code, retry_expected in cases:
            with self.subTest(code=code):
                error = HTTPError("https://nightcorelab.onrender.com/pc-node/next", code,
                                  "UPSTREAM SECRET", None, None)
                message, retry = agent._diagnose_connection(error)
                self.assertEqual(retry, retry_expected)
                self.assertIn(str(code), message)
                self.assertNotIn("UPSTREAM SECRET", message)

    def test_dns_is_identified(self):
        message, retry = agent._diagnose_connection(URLError(socket.gaierror(2, "name lookup failed")))
        self.assertTrue(retry)
        self.assertIn("DNS", message)

    def test_bounded_cold_start_retry(self):
        with patch.object(agent, "load_config", return_value=(agent.BACKEND,"not-a-real-token")):
            with patch.object(agent, "api", side_effect=[URLError("timed out"), None]) as api:
                with patch.object(agent.time, "sleep") as sleep:
                    self.assertEqual(agent.worker(once=True), 0)
        self.assertEqual(api.call_count, 2)
        sleep.assert_called_once()

    def test_unauthorized_does_not_retry(self):
        err = HTTPError(agent.BACKEND, 401, "unauthorized", None, None)
        with patch.object(agent, "load_config", return_value=(agent.BACKEND,"fake")):
            with patch.object(agent, "api", side_effect=err) as api:
                self.assertEqual(agent.worker(once=True), 2)
        api.assert_called_once()


if __name__ == "__main__":
    unittest.main()
