"""Offline contract tests; no credentials, network, or media downloads."""
import asyncio
import os
from datetime import datetime, timedelta, timezone
from email.utils import format_datetime
from pathlib import Path
import tempfile
from unittest.mock import patch
from urllib.parse import parse_qs, urlsplit
import xml.etree.ElementTree as ET

import httpx
import pytest
from fastapi.testclient import TestClient

import main
from r2_cache import R2Cache, R2Config, TTL_SECONDS


ACCOUNT = "0123456789abcdef0123456789abcdef"
BASE = {"R2_ACCESS_KEY_ID": "access", "R2_SECRET_ACCESS_KEY": "secret"}


@pytest.mark.parametrize("field,value", [
    ("R2_ACCOUNT_ID", ACCOUNT),
    ("R2_ACCOUNT_ID", f"https://{ACCOUNT}.r2.cloudflarestorage.com/Gnarly-cache"),
    ("R2_ENDPOINT_URL", ACCOUNT),
    ("R2_ENDPOINT_URL", f"https://{ACCOUNT}.r2.cloudflarestorage.com/gnarly-cache"),
])
def test_r2_config_aliases_and_endpoint_normalization(field, value):
    config = R2Config.from_env({**BASE, field: value})
    assert config.endpoint == f"https://{ACCOUNT}.r2.cloudflarestorage.com"
    assert config.bucket == "gnarly-cache"


def test_r2_config_requires_credentials_and_rejects_other_hosts():
    assert R2Config.from_env({"R2_ACCOUNT_ID": ACCOUNT}) is None
    with pytest.raises(ValueError):
        R2Config.from_env({**BASE, "R2_ENDPOINT_URL": "https://evil.example/gnarly-cache"})


def test_presigned_get_is_short_lived_and_private():
    cache = R2Cache(R2Config.from_env({**BASE, "R2_ACCOUNT_ID": ACCOUNT}),
                    client=httpx.AsyncClient())
    url = cache.presigned_get("abcdefghijk/audio.m4a", datetime(2026, 10, 20, tzinfo=timezone.utc))
    parsed = urlsplit(url)
    query = parse_qs(parsed.query)
    assert parsed.path == "/gnarly-cache/abcdefghijk/audio.m4a"
    assert query["X-Amz-Expires"] == ["900"]
    assert query["X-Amz-SignedHeaders"] == ["host"]
    assert len(query["X-Amz-Signature"][0]) == 64
    assert "secret" not in url
    assert cache.presigned_head("abcdefghijk/audio.m4a", datetime(2026, 10, 20, tzinfo=timezone.utc)) != url


def test_r2_rejects_untrusted_object_keys():
    cache = R2Cache(R2Config.from_env({**BASE, "R2_ACCOUNT_ID": ACCOUNT}),
                    client=httpx.AsyncClient())
    for key in ("../audio.m4a", "abcdefghijk/../../secret", "abcdefghijk/%2fsecret",
                "abcdefghijk/other.m4a", "abcdefghijk//audio.m4a"):
        with pytest.raises(ValueError):
            cache.presigned_get(key)


def test_head_ttl_and_hot_index():
    seen = []
    modified = datetime.now(timezone.utc) - timedelta(days=1)
    def handle(request):
        seen.append(request)
        return httpx.Response(200, headers={"Last-Modified": format_datetime(modified),
                                           "x-amz-meta-title": "U29uZw"})
    async def exercise():
        nonlocal modified
        client = httpx.AsyncClient(transport=httpx.MockTransport(handle))
        cache = R2Cache(R2Config.from_env({**BASE, "R2_ACCOUNT_ID": ACCOUNT}), client=client)
        try:
            assert await cache.find("abcdefghijk/audio.m4a") == {"title": "Song"}
            assert await cache.find("abcdefghijk/audio.m4a") == {"title": "Song"}
            assert len(seen) == 1
            modified_at, _, meta = cache._hot["abcdefghijk/audio.m4a"]
            cache._hot["abcdefghijk/audio.m4a"] = (modified_at, 0, meta)
            assert await cache.find("abcdefghijk/audio.m4a") == {"title": "Song"}
            assert len(seen) == 2
            cache._hot.clear()
            modified = datetime.now(timezone.utc) - timedelta(seconds=TTL_SECONDS + 10)
            assert await cache.find("abcdefghijk/audio.m4a") is None
        finally:
            await client.aclose()
    asyncio.run(exercise())


def test_streaming_put_preserves_filename_and_content_type():
    seen = {}
    async def handle(request):
        seen["authorization"] = request.headers.get("authorization")
        seen["type"] = request.headers.get("content-type")
        seen["length"] = request.headers.get("content-length")
        seen["disposition"] = request.headers.get("content-disposition")
        seen["body"] = await request.aread()
        return httpx.Response(200)
    async def exercise(path):
        client = httpx.AsyncClient(transport=httpx.MockTransport(handle))
        cache = R2Cache(R2Config.from_env({**BASE, "R2_ACCOUNT_ID": ACCOUNT}), client=client)
        try:
            await cache.put("abcdefghijk/audio.m4a", path, "Música", None)
        finally:
            await client.aclose()
    with tempfile.TemporaryDirectory() as folder:
        path = Path(folder) / "song.m4a"
        path.write_bytes(b"ftypM4A " * 2048)
        asyncio.run(exercise(path))
    assert seen["body"] == b"ftypM4A " * 2048
    assert seen["type"] == "audio/mp4"
    assert seen["length"] == str(len(seen["body"]))
    assert "M%C3%BAsica.m4a" in seen["disposition"]
    assert seen["authorization"].startswith("AWS4-HMAC-SHA256 ")


def test_lifecycle_merge_keeps_existing_rules():
    namespace = "http://s3.amazonaws.com/doc/2006-03-01/"
    prior = (f'<LifecycleConfiguration xmlns="{namespace}">'
             '<Rule><ID>other-rule</ID><Status>Enabled</Status>'
             '<Filter><Prefix>other/</Prefix></Filter><Expiration><Days>30</Days></Expiration></Rule>'
             '</LifecycleConfiguration>')
    saved = {}
    async def handle(request):
        assert request.url.params.get("lifecycle") == ""
        if request.method == "GET":
            return httpx.Response(200, content=prior)
        saved["xml"] = await request.aread()
        return httpx.Response(200)
    async def exercise():
        client = httpx.AsyncClient(transport=httpx.MockTransport(handle))
        cache = R2Cache(R2Config.from_env({**BASE, "R2_ACCOUNT_ID": ACCOUNT}), client=client)
        try:
            assert await cache.ensure_lifecycle()
        finally:
            await client.aclose()
    asyncio.run(exercise())
    root = ET.fromstring(saved["xml"])
    ids = [rule.findtext(f"{{{namespace}}}ID") for rule in root]
    assert ids == ["other-rule", "gnarly-cache-seven-days"]
    assert root[-1].findtext(f"{{{namespace}}}Expiration/{{{namespace}}}Days") == "7"


def test_download_r2_redirect_and_local_fallback():
    class FakeR2:
        async def find(self, _key):
            return {"title": "Song", "thumbnail": "https://example.com/cover.jpg"}
        def presigned_get(self, _key):
            return "https://0123456789abcdef0123456789abcdef.r2.cloudflarestorage.com/signed"
        def presigned_head(self, _key):
            return "https://0123456789abcdef0123456789abcdef.r2.cloudflarestorage.com/signed-head"
        async def ensure_lifecycle(self):
            return True
        async def close(self):
            pass
    with patch.object(main, "r2_cache", FakeR2()):
        with TestClient(main.app) as client:
            response = client.get("/download?url=https://www.youtube.com/watch?v=abcdefghijk",
                                  follow_redirects=False)
            assert response.status_code == 302
            assert response.headers["location"].startswith("https://")
            assert response.headers["x-cover-url"] == "https://example.com/cover.jpg"
            head = client.head("/download?url=https://www.youtube.com/watch?v=abcdefghijk",
                               follow_redirects=False)
            assert head.status_code == 302
            assert head.headers["location"].endswith("/signed-head")
            result = client.get("/download?url=https://www.youtube.com/watch?v=abcdefghijk&delivery=url")
            assert result.status_code == 200
            assert result.json()["expires_in"] == 900

    class FailedR2:
        async def find(self, _key):
            raise httpx.ConnectError("offline")
        async def ensure_lifecycle(self):
            return True
        async def close(self):
            pass
    with tempfile.TemporaryDirectory() as folder:
        file = Path(folder) / "abcdefghijk.m4a"
        file.write_bytes(b"\x00\x00\x00\x18ftypM4A ")
        with patch.object(main, "r2_cache", FailedR2()), \
             patch.object(main, "_pin_cached_audio", return_value=(file, "Song", None, "")), \
             patch.object(main, "_release_cached_reader"):
            with TestClient(main.app) as client:
                response = client.get("/download?url=https://www.youtube.com/watch?v=abcdefghijk")
                assert response.status_code == 200
                assert response.content.startswith(b"\x00\x00")
                ranged = client.get("/download?url=https://www.youtube.com/watch?v=abcdefghijk",
                                    headers={"Range": "bytes=4-7"})
                assert ranged.status_code == 206
                assert ranged.content == b"ftyp"
                head = client.head("/download?url=https://www.youtube.com/watch?v=abcdefghijk")
                assert head.status_code == 200
                assert head.content == b""


def test_r2_startup_diagnostic_logs_names_but_never_secret_values(caplog):
    import os
    keys = ("R2_ACCESS_KEY_ID", "AWS_ACCESS_KEY_ID", "S3_ACCESS_KEY_ID", "ACCESS_KEY_ID",
            "R2_SECRET_ACCESS_KEY", "AWS_SECRET_ACCESS_KEY", "S3_SECRET_ACCESS_KEY", "SECRET_ACCESS_KEY",
            "R2_ENDPOINT_URL", "R2_ACCOUNT_ID", "S3_ENDPOINT_URL", "AWS_ENDPOINT_URL")
    env = {name: "" for name in keys}
    env.update({"R2_ACCESS_KEY_ID": "NEVER_LOG_ACCESS_123",
                "R2_SECRET_ACCESS_KEY": "NEVER_LOG_SECRET_456",
                "R2_ACCOUNT_ID": ACCOUNT})
    with patch.dict(os.environ, env), patch.object(main, "r2_cache", None):
        with TestClient(main.app) as client:
            assert client.get("/health").json()["r2_enabled"] is False
    logged = caplog.text
    assert "R2 desativado; nomes de variáveis" in logged
    assert "R2_ACCESS_KEY_ID" in logged
    assert "R2_SECRET_ACCESS_KEY" in logged
    assert "R2_ACCOUNT_ID" in logged
    assert "NEVER_LOG_ACCESS_123" not in logged
    assert "NEVER_LOG_SECRET_456" not in logged
