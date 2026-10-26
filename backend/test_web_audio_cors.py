"""Browser playback CORS regression tests: do not extract media or download songs."""
import pytest
from fastapi.testclient import TestClient
import main

ALLOWED_ORIGINS = [
    "https://gnarlyweb.netlify.app",
    "https://gnarly-web.pages.dev",
    "https://gnarly-web-pages.pages.dev",
    "https://gnarly-web-stage72.pages.dev",
    "https://feat-audio-fix.gnarly-web-pages.pages.dev",
    "https://abc123ef.gnarly-web-stage72.pages.dev",
    "https://deploy-preview-8--gnarlyweb.netlify.app",
]
DENIED_ORIGINS = [
    "https://attacker.pages.dev",
    "https://gnarly-web-pages.pages.dev.attacker.example",
    "https://evil-gnarly-web-pages.pages.dev",
    "https://not-gnarlyweb.netlify.app",
    "https://gnarly-web-pages.pages.dev.evil.test",
]


@pytest.mark.parametrize("origin", ALLOWED_ORIGINS)
def test_valid_gnarly_browser_origins_receive_cors(origin):
    with TestClient(main.app) as client:
        response = client.get("/health", headers={"Origin": origin})
        assert response.status_code == 200
        assert response.headers["access-control-allow-origin"] == origin
        assert response.headers.get("access-control-allow-credentials") != "true"


@pytest.mark.parametrize("origin", ALLOWED_ORIGINS)
def test_audio_range_preflight_works_without_extraction(origin):
    with TestClient(main.app) as client:
        response = client.options(
            "/download?url=https%3A%2F%2Fwww.youtube.com%2Fwatch%3Fv%3Dabcdefghijk&delivery=browser",
            headers={
                "Origin": origin,
                "Access-Control-Request-Method": "GET",
                "Access-Control-Request-Headers": "range",
            },
        )
        assert response.status_code == 200
        assert response.headers["access-control-allow-origin"] == origin
        assert "GET" in response.headers["access-control-allow-methods"]
        assert "range" in response.headers["access-control-allow-headers"].lower()


@pytest.mark.parametrize("origin", DENIED_ORIGINS)
def test_untrusted_sites_are_not_granted_audio_cors(origin):
    with TestClient(main.app) as client:
        response = client.get("/health", headers={"Origin": origin})
        assert response.status_code == 200
        assert "access-control-allow-origin" not in response.headers


def test_range_and_audio_headers_are_exposed_to_browser():
    with TestClient(main.app) as client:
        r = client.options("/download", headers={
            "Origin": "https://gnarly-web-pages.pages.dev",
            "Access-Control-Request-Method": "GET",
            "Access-Control-Request-Headers": "range",
        })
        assert r.status_code == 200
        # An ordinary GET response exposes these headers; preflight confirms the
        # Range header is allowed and never tries to fetch a YouTube recording.
        health = client.get("/health", headers={"Origin": "https://gnarly-web-pages.pages.dev"})
        exposed = health.headers["access-control-expose-headers"].lower()
        assert "content-range" in exposed
        assert "accept-ranges" in exposed
