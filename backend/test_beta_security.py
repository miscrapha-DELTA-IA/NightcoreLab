"""Beta hardening contracts; only mocked local calls, no real credentials."""
from unittest.mock import patch

from fastapi.responses import JSONResponse
from fastapi.testclient import TestClient

import main
from access_control import AccessControl


VIDEO_URL = "https://www.youtube.com/watch?v=abcdefghijk"


def test_public_health_does_not_disclose_cookie_file_metadata(monkeypatch):
    monkeypatch.delenv("GNARLY_METRICS_TOKEN", raising=False)
    with TestClient(main.app) as client:
        health = client.get("/").json()
        assert health["status"] == "ok"
        assert "cookies" not in health
        assert "cookies_env" not in health
        assert "cookies_summary" not in health
        assert "secret_files" not in health
        assert client.get("/metrics").status_code == 404


def test_ticket_authorizes_one_download_without_token_header():
    async def cached(*_args, **_kwargs):
        return JSONResponse({"status": "cached"}, status_code=200)

    with patch.object(main, "_access_control", AccessControl({
        "GNARLY_AUTH_MODE": "strict",
        "GNARLY_ACCESS_TOKENS": "friend-a"
    })), patch.object(main, "_try_r2", side_effect=cached):
        with TestClient(main.app) as client:
            issue = client.post("/access-ticket", json={"url": VIDEO_URL},
                                headers={"X-Gnarly-Token": "friend-a"})
            assert issue.status_code == 200
            ticket = issue.json()["ticket"]
            assert ticket and issue.headers.get("cache-control") == "no-store"
            query = {"url": VIDEO_URL, "ticket": ticket}
            assert client.get("/download", params=query).status_code == 200
            assert client.get("/download", params=query).status_code == 403
            assert client.get("/download", params={"url": VIDEO_URL}).status_code == 403


def test_ticket_rejects_untrusted_source_or_credential():
    with patch.object(main, "_access_control", AccessControl({
        "GNARLY_AUTH_MODE": "strict",
        "GNARLY_ACCESS_TOKENS": "friend-a"
    })):
        with TestClient(main.app) as client:
            assert client.post("/access-ticket", json={"url": VIDEO_URL},
                               headers={"X-Gnarly-Token": "incorrect"}).status_code == 403
            assert client.post("/access-ticket", json={
                "url": "http://www.youtube.com/watch?v=abcdefghijk"},
                headers={"X-Gnarly-Token": "friend-a"}).status_code == 400
