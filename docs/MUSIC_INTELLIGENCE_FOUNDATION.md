# Music Intelligence — Foundation

This optional, offline service reuses `AudioFeatureAnalyzer` and its existing
`AudioFFTSpectrum`. It does not own or configure AVAudioEngine, playback, queue,
lyrics, shaders, microphone capture or machine-learning models.

## Contracts

- `AudioAssetDescriptor`: canonical local URL, URL-derived asset ID, full-file
  SHA-256 source revision, duration and audio format. A moved file has a new asset
  ID; replacing bytes at the same URL changes the revision even when size and
  modification date are unchanged. Hashing uses 1 MiB chunks on a utility worker.
- `MusicAnalysisResult`: immutable Codable/Sendable snapshot with independent
  energy/onset statuses, source identity, schema/analyzer versions, original-time
  timeline, onset events and coverage. Spectral bands are preserved in the
  existing timeline. Onsets remain energy-rise heuristics, not BPM or a beat grid.
- `MusicAnalysisCache`: atomic JSON writes in the system caches directory. One
  slot per asset; revision/schema/analyzer mismatches and corrupt data are misses.
  Successful energy survives onset failure and is reused when onsets are retried.
  Cache failures do not fail analysis. Oldest-accessed files are evicted above
  64 MiB. The operating system may also evict this disposable cache.
- `AnalysisScheduler`: FIFO, one utility job at a time by default. The canonical
  URL deduplicates *in-flight* identity and DSP work; completed jobs are removed.
  Each consumer has its own continuation and cancellation. A worker is cancelled
  only after its final consumer leaves; its slot stays occupied until it exits.
- `MusicIntelligenceEngine`: hashes the source, checks persistent cache, runs the
  existing analyzer on misses and verifies the source again before publishing
  analyzed data. No stale in-memory result is accepted solely because URLs match.

`analysis(for:onUpdate:)` returns a terminal snapshot. Optional callbacks receive
identity/pending, energy-ready/onsets-pending, then terminal snapshots (a complete
cache hit emits only the cached terminal result). These are capability-level
partials, not incremental decoding chunks. Callbacks run on the scheduler actor,
must be brief, and must explicitly hop to MainActor for UI work. Consumers must
check identity and their own request generation before displaying updates.

The first implementation has only energy and onset capabilities. A failed energy
decode also makes its dependent onset extraction unavailable; an onset failure
does not discard energy. Source identity errors and cancellation throw. DSP errors
return failed capability statuses; successful capabilities can still be consumed.

## Integration and timing

`AudioFeatureEngine` remains the compatibility bridge for Creative. It clears old
state before each preparation and guards completion with its request generation.
`analysisTimeline(for:)` gives export an independent service subscription without
replacing live state. `StoryDraftPreview` freezes the returned timeline for both
preview and MP4. Existing source timestamps, the Marble resolver and rendering
code are unchanged. Analysis failure leaves playback independent and visuals
neutral. The existing live Low Power Mode guard is retained.

All persisted timestamps are original source seconds. The existing ~12 Hz
analyzer still caps decoding at 20 minutes. Coverage reports the analyzed prefix
separately from total source duration; queries beyond it remain silent.

## Cost and limitations

Cache hits skip decoding and FFT, but still read/hash the source for reliable
revision validation (including a second verification before returning data).
This is O(file bytes) I/O, not a zero-cost lookup. Cold analysis adds the same
hashing to the existing DSP cost; concurrent consumers share that work. No work
is added to the audio render callback or to per-frame visual sampling.

The scheduler bounds expensive work to one job; a queued cache lookup may wait
behind a cold analysis. The timeline is still held in memory by active visual
consumers. Disk use is bounded to 64 MiB after successful writes, with temporary
headroom needed for atomic replacement. Cache eviction causes recomputation.
There is no filesystem watcher: external replacement of a source already in use
is detected on the next service request, not on every visual frame. A source
changed during the analysis validation window is rejected and can be requested
again. Device latency, memory and thermal measurements remain a follow-up on
physical hardware; no numeric speedup is claimed.

## Validation

`MusicIntelligenceTests` covers persistent hits, misses, same-path/same-size file
replacement, corrupt/obsolete cache, persistence failure, source mutation during
analysis, partial success/retry, bridge invalidation and incomplete coverage.
`AnalysisSchedulerTests` covers shared work, independent/last-consumer
cancellation, queued cancellation and concurrency bounds. Existing FFT and
timestamp-rendering tests remain regression coverage.

Run `xcodegen generate`, build the NightcoreLab scheme, then run its full XCTest
target on an iOS simulator. The existing main-branch iOS workflow performs these
steps on macOS and also builds the unsigned Release application.
