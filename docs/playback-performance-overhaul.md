# Bounded progressive playback coordination

Baseline: `7644b2a`. Branch: `perf/playback-responsiveness`.
No native iOS source, API contract, deployment configuration or credentials changed.

## Root causes and changes

`/stream` previously ran independent yt-dlp discovery on every request, with a 13s
waiter timeout, even if `/prepare` already owned an extraction. Range/seek requests
could repeat expensive work. Timed-out threads could continue to occupy the shared gate.

`fast_stream.ProgressiveDiscovery` now shares at most two actual metadata tasks per
process, retains worker ownership after waiter timeout/cancellation, caches up to 64
results (180s positive / 8s negative), and waits at most 2.5s per HTTP waiter. Busy
process gates return quickly instead of adding metadata work behind foreground jobs.
Signed URLs remain private. Rejected signed sources are invalidated for later retry.

`/stream` reuses an existing prepared extraction; `/download` still shares the existing
canonical-ID extraction map. `/prepare` declines additional distinct speculative work
when preparation is already reserved or download slots are full. Last-consumer disconnect
no longer cancels a queued job retained by preparation. Complete R2/local caches stay
available. Metrics add anonymous discovery and extraction counters/duration aggregates.

No parallel extraction hedging was introduced. Download fallback may still need its own
legacy format resolution. Python cannot terminate a running yt-dlp thread, so deadlines
bound the HTTP wait and admission, rather than claiming to bound provider execution time.
Sharing is process-local and existing actual worker/concurrency bounds remain in place.

## Measurements

`python scripts/benchmark_progressive_discovery.py` uses twenty simultaneous same-ID
requests, synthetic 40ms metadata and two worker slots. It compares the previous
independent-call pattern with the actual new coordinator, without provider traffic.

| Fixture | Metadata calls | p50 | p95 | p99 |
| --- | ---: | ---: | ---: | ---: |
| Before | 20 | 221.6ms | 402.4ms | 402.8ms |
| After | 1 | 40.8ms | 40.9ms | 40.9ms |

Raw results: `playback-discovery-benchmark.json`. These are coordination measurements,
not live extraction duration or browser acoustic TTFAP. Complete app browser timing and
root-cause report are in the companion GNARLY WEB performance branch.

## Validation and limits

- Baseline pytest: 126 passed, 38 subtests.
- Updated pytest: 134 passed, 38 subtests; unittest discovery: 89 passed.
- Coverage includes shared discovery, expiry/negative retry, actual concurrency ownership,
  canceled waiters, preparation joining, admission and disconnect retention. Existing
  R2, Range/browser CORS, resource control, provider failure, search and API tests pass.
- Existing FastAPI on_event deprecation warnings remain; no tests were weakened/deleted.
- Production `/` health probe timed out after 25s with no response; no provider/audio
  workload was sent. This does not establish production health or explain the timeout.
- No backend deployment or production merge performed. Validate real provider timings,
  PR CI, native client and long listening sessions before rollout. Revert the focused
  runtime commit to restore prior behavior independently of frontend delivery improvements.
