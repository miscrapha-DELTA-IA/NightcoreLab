"""Browser-only R2 passthrough: no 302, no RAM buffering, Range preserved."""
import unittest
from unittest.mock import AsyncMock, patch
import httpx
import main
from r2_cache import R2Cache, R2Config
from starlette.responses import StreamingResponse

class R2BrowserPlaybackTests(unittest.IsolatedAsyncioTestCase):
    async def test_cached_range_is_internal_stream(self):
        seen = []
        class AudioStream(httpx.AsyncByteStream):
            async def __aiter__(self):
                yield b"abcd"

            async def aclose(self):
                pass

        def handler(request):
            seen.append(request)
            self.assertEqual(request.headers.get("range"), "bytes=0-3")
            return httpx.Response(206, stream=AudioStream(),
                                  headers={"content-range": "bytes 0-3/100",
                                           "accept-ranges": "bytes",
                                           "content-length": "4"})
        client = httpx.AsyncClient(transport=httpx.MockTransport(handler))
        cfg = R2Config("https://" + "a" * 32 + ".r2.cloudflarestorage.com",
                       "gnarly-cache", "test-access", "test-secret")
        cache = R2Cache(cfg, client=client)
        cache.find = AsyncMock(return_value={"title": "Test", "thumbnail": ""})
        with patch.object(main, "r2_cache", cache):
            result = await main._try_r2("abcdefghijk", "browser",
                                        browser_range="bytes=0-3")
            self.assertIsInstance(result, StreamingResponse)
            self.assertEqual(result.status_code, 206)
            self.assertEqual(result.headers["content-range"], "bytes 0-3/100")
            self.assertEqual(result.headers["x-gnarly-playback-source"], "r2-stream")
            self.assertEqual(b"".join([x async for x in result.body_iterator]), b"abcd")
            await result.background()
        await client.aclose()
        self.assertEqual(len(seen), 1)

    async def test_upstream_403_falls_back_instead_of_redirect(self):
        client = httpx.AsyncClient(transport=httpx.MockTransport(
            lambda request: httpx.Response(403, text="denied")))
        cfg = R2Config("https://" + "a" * 32 + ".r2.cloudflarestorage.com",
                       "gnarly-cache", "test-access", "test-secret")
        cache = R2Cache(cfg, client=client)
        cache.find = AsyncMock(return_value={"title": "Test"})
        with patch.object(main, "r2_cache", cache):
            result = await main._try_r2("abcdefghijk", "browser")
            self.assertIsNone(result)
        await client.aclose()

if __name__ == "__main__":
    unittest.main()
