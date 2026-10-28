"""Fast-stream safe-source, HTTP Range and preparation regression tests."""
import asyncio
import unittest
from unittest.mock import AsyncMock, MagicMock, patch
import fast_stream

def audio_info(**override):
    base={
      "duration":184,
      "formats":[{
       "format_id":"140","ext":"m4a","acodec":"mp4a.40.2",
       "vcodec":"none","protocol":"https","abr":128,
       "url":"https://rr1---sn-xyz.googlevideo.com/videoplayback?id=x&sig=abc",
       "filesize":4_000_000
      }]
    }
    base.update(override)
    return base


class ProgressiveSourceTests(unittest.TestCase):
    def test_accepts_verified_direct_mp4(self):
        source=fast_stream.choose_progressive_source(audio_info())
        self.assertIsNotNone(source)
        self.assertEqual(source.format_id,"140")

    def test_rejects_redirects_private_hosts_and_formats(self):
        for url in ("https://evil.example/a", "http://rr.googlevideo.com/file",
                    "https://googlevideo.com.evil.test/a",
                    "https://localhost/private",
                    "https://user:pass@rr.googlevideo.com/a",
                    "https://rr.googlevideo.com:8080/a"):
            self.assertFalse(fast_stream.valid_google_audio_url(url))
        for options in ({"duration":600}, {"duration":0}, {"is_live":True},
                        {"duration":None}):
            self.assertIsNone(fast_stream.choose_progressive_source(audio_info(**options)))
        for field,value in (("ext","webm"),("acodec","opus"),
                            ("vcodec","avc1"),("fragments",[{"url":"other"}]),
                            ("url","https://evil.test/stream"),("filesize",80_000_000)):
            item=audio_info()["formats"][0].copy()
            item[field]=value
            self.assertIsNone(fast_stream.choose_progressive_source(audio_info(formats=[item])))

    def test_strict_single_range_and_safe_headers(self):
        for value in ("bytes=0-1","bytes=0-","bytes=-100"):
            self.assertEqual(fast_stream.safe_range(value),value)
        for value in ("bytes=0-2,3-4","bytes=1-0\nCookie:a","other","bytes=garbage"):
            with self.assertRaises(ValueError): fast_stream.safe_range(value)
        upstream=MagicMock(status_code=206,headers={
         "Content-Length":"512","Content-Range":"bytes 0-511/4096",
         "Accept-Ranges":"bytes","Set-Cookie":"private",
         "Location":"https://private.googlevideo.com/stream"})
        forwarded=fast_stream.forwarded_audio_headers(upstream)
        self.assertNotIn("Set-Cookie",forwarded)
        self.assertNotIn("Location",forwarded)
        self.assertEqual(forwarded["content-range"],"bytes 0-511/4096")

class BackendPrepareTests(unittest.IsolatedAsyncioTestCase):
    async def test_one_background_preparation_is_reused(self):
        import main
        from pydantic import HttpUrl
        video="ABCDEFGHIJK"
        url="https://www.youtube.com/watch?v="+video
        pending=asyncio.Future()
        with patch.object(main,"in_flight_downloads",{}),\
             patch.object(main,"_shared_extraction",new=AsyncMock(side_effect=lambda u:pending)),\
             patch.object(main,"r2_cache",None),\
             patch.object(main,"_pin_cached_audio",return_value=None),\
             patch.object(main,"_rss_bytes",return_value=0),\
             patch.object(main,"_check_youtube_cooldown",return_value=None):
            resp=await main.prepare_next_track(main.DownloadRequest(url=HttpUrl(url)))
            self.assertEqual(resp.status_code,202)
            resp2=await main.prepare_next_track(main.DownloadRequest(url=HttpUrl(url)))
            self.assertEqual(resp2.status_code,202)
            self.assertEqual(len(main.in_flight_downloads),1)
            pending.set_exception(RuntimeError("offline test origin"))
            await asyncio.sleep(0.03)


if __name__=="__main__":
    unittest.main()
