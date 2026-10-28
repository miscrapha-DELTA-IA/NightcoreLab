"""Fast-stream safe-source, HTTP Range and preparation regression tests."""
import asyncio
import unittest
from unittest.mock import AsyncMock, MagicMock, patch
import fast_stream
import httpx

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
        upstream=MagicMock(status_code=206,headers=httpx.Headers({
         "Content-Length":"512","Content-Range":"bytes 0-511/4096",
         "Accept-Ranges":"bytes","Set-Cookie":"private",
         "Location":"https://private.googlevideo.com/stream"}))
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


class DiscoveryConcurrencyTests(unittest.IsolatedAsyncioTestCase):
    async def test_singleflight_and_metadata_cache_for_ranges(self):
        import threading
        calls=[]
        def load():
            calls.append(1)
            return fast_stream.choose_progressive_source(audio_info())
        cache=fast_stream.ProgressiveDiscovery()
        results=await asyncio.gather(*[cache.get('same',load) for _ in range(20)])
        self.assertEqual(len(calls),1)
        self.assertTrue(all(x is results[0] for x in results))
        self.assertIs(await cache.get('same',load),results[0])
        self.assertEqual(cache.snapshot()['joins'],19)
        self.assertEqual(cache.snapshot()['hits'],1)

    async def test_timeout_does_not_release_a_live_thread_or_duplicate_discovery(self):
        import threading
        released=threading.Event()
        calls=[]
        def load():
            calls.append(1)
            released.wait(1)
            return None
        cache=fast_stream.ProgressiveDiscovery(timeout=.01,concurrency=1)
        try:
            self.assertIsNone(await cache.get('same',load))
            self.assertEqual(len(cache.pending),1)
            self.assertIsNone(await cache.get('other',load))
            self.assertIsNone(await cache.get('same',load))
            self.assertEqual(len(calls),1)
        finally:
            released.set()
            await asyncio.gather(*cache.pending.values())
        self.assertEqual(len(cache.pending),0)

    async def test_negative_cache_expires_and_history_is_bounded(self):
        clock=[0]
        cache=fast_stream.ProgressiveDiscovery(clock=lambda:clock[0],capacity=2)
        calls=[]
        def load():calls.append(1);return None
        await cache.get('a',load);await cache.get('a',load)
        self.assertEqual(len(calls),1)
        clock[0]=9
        await cache.get('a',load)
        self.assertEqual(len(calls),2)
        await cache.get('b',load);await cache.get('c',load)
        self.assertEqual(len(cache.cache),2)

    async def test_canceled_waiter_does_not_cancel_shared_resolution(self):
        import threading
        released=threading.Event()
        def load():released.wait(1);return fast_stream.choose_progressive_source(audio_info())
        cache=fast_stream.ProgressiveDiscovery()
        waiter=asyncio.create_task(cache.get('same',load))
        await asyncio.sleep(.01);waiter.cancel()
        with self.assertRaises(asyncio.CancelledError):await waiter
        released.set()
        self.assertIsNotNone(await cache.get('same',load))
        self.assertEqual(cache.started,1)

    async def test_transient_discovery_failure_has_a_short_negative_ttl(self):
        cache=fast_stream.ProgressiveDiscovery()
        calls=[]
        def fail():calls.append(1);raise ValueError('temporary provider failure')
        with self.assertRaises(ValueError):await cache.get('same',fail)
        self.assertIsNone(await cache.get('same',fail))
        self.assertEqual(len(calls),1)

    async def test_stream_reuses_preparing_job_before_metadata_discovery(self):
        import main
        from pydantic import HttpUrl
        from starlette.requests import Request
        from fastapi import BackgroundTasks
        response=MagicMock()
        with patch.object(main,'_pin_cached_audio',return_value=None),\
             patch.object(main,'in_flight_downloads',{'ABCDEFGHIJK':object()}),\
             patch.object(main,'download',new=AsyncMock(return_value=response)) as download,\
             patch.object(main,'_discover_progressive_aac') as discover:
            result=await main.progressive_audio(HttpUrl('https://youtube.com/watch?v=ABCDEFGHIJK'),
              Request({'type':'http','headers':[(b'range',b'bytes=0-')]}),BackgroundTasks())
            self.assertIs(result,response)
            self.assertFalse(download.call_args.kwargs['redirect_cache'])
            self.assertEqual(download.call_args.kwargs['browser_range'],'bytes=0-')
            discover.assert_not_called()

    async def test_prepare_reservation_survives_last_download_waiter_disconnect(self):
        import main
        pending=asyncio.create_task(asyncio.sleep(10))
        entry=main.InFlightDownload(task=pending)
        entry.consumers=1
        with patch.object(main,'_preparing_watchers',{'ABCDEFGHIJK'}):
            await main._release_download('ABCDEFGHIJK',entry)
            await asyncio.sleep(0)
            self.assertFalse(pending.cancelled())
            self.assertFalse(pending.done())
        pending.cancel()
        with self.assertRaises(asyncio.CancelledError):await pending

    async def test_prepare_declines_additional_speculation(self):
        import main
        from pydantic import HttpUrl
        from fastapi import HTTPException
        with patch.object(main,'_pin_cached_audio',return_value=None),\
             patch.object(main,'in_flight_downloads',{}),\
             patch.object(main,'_preparing_watchers',{'BBBBBBBBBBB'}),\
             patch.object(main,'r2_cache',None),\
             patch.object(main,'_check_youtube_cooldown'),\
             patch.object(main,'_rss_bytes',return_value=0):
            with self.assertRaises(HTTPException) as raised:
                await main.prepare_next_track(main.DownloadRequest(url=HttpUrl('https://youtube.com/watch?v=ABCDEFGHIJK')))
            self.assertEqual(raised.exception.status_code,429)


if __name__ == "__main__":
    unittest.main()
