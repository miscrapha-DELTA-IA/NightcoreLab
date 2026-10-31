"""PC audio node: authentication, bounded queue, validated upload and native routing."""
import asyncio
from pathlib import Path
import tempfile
import time
import unittest
from unittest.mock import AsyncMock, patch

from fastapi.responses import Response
from fastapi.testclient import TestClient

import main
import pc_audio_bridge as bridge

ID = "ABCDEFGHIJK"
TOKEN = "w" * 60
HEADERS = {"Authorization": "Bearer " + TOKEN}
M4A = b"\x00\x00\x00\x18ftypM4A " + b"\x00" * 2048


class PcNodeQueueTests(unittest.TestCase):
    def setUp(self):
        self.env = patch.dict("os.environ", {"GNARLY_PC_NODE_TOKEN": TOKEN})
        self.env.start()
        self.q = bridge.AudioNodeQueue()

    def tearDown(self):
        self.env.stop()

    def test_heartbeat_and_exact_id_only(self):
        self.assertFalse(self.q.online())
        self.q.heartbeat()
        self.assertTrue(self.q.online())
        self.assertIsNone(self.q.request("../fake"))
        j = self.q.request(ID)
        self.assertIsNotNone(j)
        self.assertIs(self.q.request(ID), j)
        name, lease = self.q.lease_next()
        self.assertEqual(name, ID)
        self.assertTrue(self.q.validate_lease(ID, lease))
        self.assertFalse(self.q.validate_lease(ID, "wrong"))
        self.assertTrue(self.q.finish(ID, lease, success=True))
        self.assertEqual(j.state, "ready")
        self.assertFalse(self.q.validate_lease(ID, lease))

    def test_no_unauthenticated_node_access(self):
        self.assertFalse(self.q.authorized("Bearer " + "b" * 60))
        self.assertFalse(self.q.authorized(""))
        self.assertTrue(self.q.authorized(HEADERS["Authorization"]))

    def test_long_extraction_keeps_origin_online_without_new_polls(self):
        now = [0.]
        q = bridge.AudioNodeQueue(now=lambda: now[0])
        q.heartbeat()
        q.request(ID)
        _, lease = q.lease_next()
        now[0] = bridge.ONLINE_SECONDS + 80
        self.assertTrue(q.online(), "Active Windows lease keeps Render egress disabled")
        self.assertTrue(q.validate_lease(ID, lease))
        self.assertEqual(q.status(ID)["state"], "leased")
        self.assertTrue(q.finish(ID, lease, success=True))
        self.assertTrue(q.online(), "Verified upload refreshes the worker heartbeat")
        now[0] += bridge.ONLINE_SECONDS + 1
        self.assertFalse(q.online(), "Completed jobs do not fake permanent availability")

    def test_failed_job_may_retry_after_bounded_delay(self):
        now = [10.]
        q = bridge.AudioNodeQueue(now=lambda: now[0])
        q.heartbeat()
        first = q.request(ID)
        _, lease = q.lease_next()
        self.assertTrue(q.finish(ID, lease, success=False))
        self.assertIs(q.request(ID), first)
        now[0] += bridge.FAILED_RETRY_SECONDS + 1
        q.heartbeat()
        later = q.request(ID)
        self.assertIsNot(later, first)
        self.assertEqual(later.state, "pending")

    def test_bounded_job_queue(self):
        self.q.heartbeat()
        for index in range(bridge.MAX_JOBS):
            self.assertIsNotNone(self.q.request(f"{index:011d}"))
        self.assertIsNone(self.q.request("ABCDEF12345"))
        video_id, lease = self.q.lease_next()
        self.assertTrue(self.q.finish(video_id, lease, success=True))
        # A ready/cached recording no longer blocks another unique request.
        self.assertIsNotNone(self.q.request("ABCDEF12345"))


class PcNodeEndpointsTests(unittest.TestCase):
    def setUp(self):
        self.env = patch.dict("os.environ", {"GNARLY_PC_NODE_TOKEN": TOKEN})
        self.env.start()
        self.q = bridge.AudioNodeQueue()
        self.patch_queue = patch.object(bridge, "queue", self.q)
        self.patch_queue.start()
        self.client = TestClient(main.app)

    def tearDown(self):
        self.patch_queue.stop()
        self.env.stop()

    def test_browser_can_read_status_without_lease_or_token(self):
        self.assertEqual(self.client.get("/pc-node/status/unsafe").status_code,400)
        self.assertEqual(self.client.get("/pc-node/status/"+ID).json()["state"],"absent")
        self.client.get("/pc-node/next", headers=HEADERS)
        self.q.request(ID)
        status=self.client.get("/pc-node/status/"+ID)
        self.assertEqual(status.status_code,200)
        self.assertEqual(status.json()["state"],"pending")
        self.assertTrue(status.json()["node_online"])
        self.assertNotIn("lease", status.text)
        self.assertEqual(status.headers.get("cache-control"), "no-store")

    def test_poll_auth_and_lease(self):
        self.assertEqual(self.client.get("/pc-node/next").status_code, 401)
        self.assertEqual(self.client.get("/pc-node/next", headers=HEADERS).status_code, 204)
        self.assertTrue(self.q.online())
        self.assertIsNotNone(self.q.request(ID))
        response = self.client.get("/pc-node/next", headers=HEADERS)
        self.assertEqual(response.status_code, 200)
        self.assertEqual(response.json()["video_id"], ID)
        self.assertEqual(self.client.post("/pc-node/fail/" + ID,
            headers={**HEADERS, "X-Gnarly-Lease": "invalid"}).status_code, 409)
        self.assertEqual(self.client.post("/pc-node/fail/" + ID,
            headers={**HEADERS, "X-Gnarly-Lease": response.json()["lease"]}).status_code, 200)

    def test_rejects_fake_audio_and_requires_correct_lease(self):
        self.client.get("/pc-node/next", headers=HEADERS)
        self.q.request(ID)
        lease = self.client.get("/pc-node/next", headers=HEADERS).json()["lease"]
        path = "/pc-node/upload/" + ID
        self.assertEqual(self.client.put(path, data=M4A).status_code, 401)
        self.assertEqual(self.client.put(path, data=M4A,
             headers={**HEADERS, "X-Gnarly-Lease":"fake"}).status_code, 409)
        self.assertEqual(self.client.put(path, data=b"<html>" + b" " * 2000,
             headers={**HEADERS, "X-Gnarly-Lease":lease}).status_code, 422)
        self.assertEqual(self.q.snapshot()["leased"],1)

    def test_valid_audio_reaches_existing_r2_pipeline(self):
        self.client.get("/pc-node/next", headers=HEADERS)
        self.q.request(ID)
        lease = self.client.get("/pc-node/next", headers=HEADERS).json()["lease"]
        output = (main.CACHE_DIR / (ID+".m4a"), ID, None, "/tmp")
        with patch.object(main, "_cache_extracted_audio", return_value=output) as save, \
             patch.object(main, "_schedule_r2_upload") as upload:
            response = self.client.put("/pc-node/upload/"+ID, content=M4A,
                headers={**HEADERS, "X-Gnarly-Lease":lease})
        self.assertEqual(response.status_code, 200)
        self.assertEqual(self.q.snapshot()["ready"], 1)
        save.assert_called_once()
        upload.assert_called_once()

    def test_live_node_keeps_playback_ready_during_render_cooldown(self):
        self.client.get("/pc-node/next", headers=HEADERS)
        with patch.object(main, "_youtube_cooldown_until", time.monotonic()+120):
            reply = self.client.get("/playback-status")
        self.assertEqual(reply.json()["status"],"ready")
        self.assertTrue(reply.json()["pc_node_online"])
        self.assertGreater(reply.json()["youtube_retry_after"], 0)

    def test_native_stream_waits_for_worker_not_youtube(self):
        self.client.get("/pc-node/next", headers=HEADERS)
        audio = Response(content=M4A, media_type="audio/mp4")
        with patch.object(self.q, "wait", new=AsyncMock(return_value="ready")) as waiting, \
             patch.object(main, "_pin_cached_audio",
                          side_effect=[None,(main.CACHE_DIR / (ID+".m4a"),ID,None,None)]), \
             patch.object(main, "_audio_response", return_value=audio), \
             patch.object(main, "_discover_progressive_aac",
                          side_effect=AssertionError("Render egress must not run")):
            response = self.client.get("/stream", params={
                "url":"https://www.youtube.com/watch?v="+ID})
        self.assertEqual(response.status_code, 200)
        waiting.assert_awaited_once()


if __name__ == "__main__":
    unittest.main()
