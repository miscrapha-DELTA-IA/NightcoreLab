# NightcoreLab — Performance audit (2026-10-10)

## Concrete findings
- `yt-dlp` previously used one fragment at a time (default). Now `concurrent_fragment_downloads=4` accelerates DASH/HLS *where the source is fragmented*. Regular single-file M4A may not improve.
- The API discarded completed audio after the response; it now publishes `.m4a` and metadata atomically to an on-disk cache with a 300 MiB eviction threshold.
- LRU evicts oldest audio by last access, pins active FileResponse readers, and avoids copying files when the cache and extraction workspace share the same volume.
- File delivery stays `FileResponse`, avoiding whole-audio allocations in RAM.
- Blocking download, cache lookup/insertion and workspace cleanup run through `asyncio.to_thread`. Lightweight state synchronization stays on the event loop.
- Global semaphore still allows at most two separate heavy yt-dlp extractions per Python process.
- UI status fades in/out with a short 180 ms animation without introducing extra network activity.
- AVAudioEngine audio completion, notification observers and remote command handlers already use `[weak self]`, so no new weak references were added unnecessarily.

## Caveats
- Render's `/tmp` is ephemeral: cache lasts across requests and may survive restarts reusing the same filesystem, but is **not durable** across redeploys, moved containers, or machine replacement.
- Cache size is bounded to 300 MiB of cached audio. Extraction workspaces, system and application files remain additional disk usage; active readers are not evicted until released.
- Fragment parallelism may increase upstream request pressure. Monitor YouTube 429 and reduce to 2 if rate limits worsen.
- In-memory deduplication and semaphore are per worker, not distributed.
- There is no controlled network benchmark or Instruments trace in CI; no speedup percentage is claimed.
- Downloading media must respect the source's rights and service terms.

## Verification
Backend: `python -m unittest discover -s backend -p 'test_*.py'`.
iOS: `xcodebuild test -project NightcoreLab.xcodeproj -scheme NightcoreLab -destination '<simulator>'`.
