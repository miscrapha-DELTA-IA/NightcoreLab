# Spotifast → NightcoreLab: architectural audit and adoption

Baseline: `stage-16a-discovery-engine`. Incremental branch:
`stage-17-spotifast-playback-foundation`. This is a **stacked PR**, not a
replacement for Stage 16A. No merge to main is implied.

## Provenance and license

Inspected upstream [Spotifast](https://github.com/crmne/spotifast):
`src/player.rs`, `src/backend.rs`, `src/vis.rs`, `src/history.rs`,
`src/lyrics.rs`, `src/images.rs`, `src/account_cache.rs`,
`src/credentials.rs`, `src/sink.rs`, `Cargo.toml`, `LICENSE`.
Spotifast's license is MIT, copyright (c) 2026 Carmine Paolino.
**Only architectural ideas were adopted; no source code copied.**
No Rust crates, egui, librespot, fastframe, projectM/MilkDrop or Spotify
audio access have been added. The NightcoreLab repository currently exposes
no root LICENSE; release licensing must be decided by its maintainer.

## Existing NightcoreLab (reuse before building)

| Domain | Existing single owner | Gap / adaptation |
| --- | --- | --- |
| Audio + clock | `AudioEngineManager`, `EnginePlaybackClock` (AVAudioEngine) | Confirm desired vs actual playback and reconcile transitions |
| Queue | `PlaybackQueue` in ContentView; two-entry prefetch in `AudioDownloadManager` | Consolidate commands without changing queue semantics |
| Navigation | `PlaybackNavigationHistory` | Retain independent back/forward stack |
| Session | `SavedPlaybackSession` (UserDefaults, metadata + position) | Versioning and richer context only with safe migration |
| History | `PlayHistoryStore`, local DiscoveryEventLog | Never duplicate history into coordinator |
| Omnibox | `OmniboxEngine`: 220ms debounce, one cancellable task, NSCache | Request generations, TTL, partial states, stale fallback |
| Metadata | `YouTubeSearchService` (backend NDJSON), `AudioDownloadManager` | Gateway contracts only when useful, no premature Spotify |
| Audio cache | `TrackAudioCache`: 30 files / 512 MiB, LRU, atomic JSON index | Eviction safety and tests; avoid redundant cache layer |
| Lyrics | `LyricsStore`, `LyricsPrefetcher`, LRCLIB | Existing positive/negative TTL; reject obsolete responses |
| FFT and visuals | Existing MusicIntelligence / RhythmAnalyzer and Creative runtime | Measure latency, do not add a second AVAudioEngine/tap |
| Creative presets | `CreativePresetPackage` schema v1 + preview descriptor and validators | Extend v1 compatibly; no new renderer/equation ownership |
| System media | `MPNowPlayingInfoCenter`, play/pause/toggle remote, interruptions, route changes | Add next/previous/seek callbacks in later incremental stage |

Deployment: iOS 17, XcodeGen, Swift 5 concurrency mode minimal.
SwiftPM: DownloadKit (lcharlick/DownloadManager pinned revision),
SDWebImageSwiftUI (pinned revision). Backend: FastAPI, yt-dlp, ytmusicapi,
cachetools, Deno and certifi. Existing `PrivacyInfo.xcprivacy` unchanged.

## First implemented increment: transport foundation

- `PlaybackCoordinator` holds requested command, confirmed transport projection
  (idle/loading/playing/paused/seeking/ended/failed), and a generation token.
- Legacy `PlaybackTransitionCoordinator` is a typealias; old tests/callers
  remain compatible. `AudioEngineManager.isPlaying` is still authoritative.
- Coordinator delegates queue commits, history navigation, session persistence
  and queue clearing to existing owners; no duplicated mutable queue/session.
- SwiftUI play/pause and scrubbing route through the coordinator.
- `TrackIdentity` namespaces YouTube/Spotify/local source IDs, while old
  `Track` remains YouTube-backed with byte-compatible Codable shape.
- Audio graph, prefetch limit, visual/effect pipeline, lyrics and UI styling
  are unchanged. Local imported files are not artificially assigned YouTube IDs.
- New focused tests cover command reconciliation, late callbacks, committed
  queue transitions, and source/legacy serialization.

## Implementation order and exit criteria

1. **Foundation (this PR):** coordinator, confirmed states, limited command
   routing, namespaced identity, tests, architecture documentation.
2. **Robustness:** Omnibox request-generation guard; TTL/stale fallback;
   bounded negative results; safe session schema migration; no new backend
   dependencies without justification.
3. **Audio/system:** measure actual output/display lag before any tap changes;
   output-device, Low Power, Reduce Motion and background matrix; remote
   next/previous/seek via the same coordinator; preview/export frame parity.
4. **Presets:** extend existing package version with backward decoding,
   curated favorites/history and validated imports. Do not duplicate
   composition/material/typography state.
5. **Sources:** implement capability-based metadata gateways as needed;
   Spotify (optional) only metadata/library/playlists with OAuth + Keychain
   and reviewed policy. Never download/rebroadcast Spotify audio.

## Known limitations and release gates

- Transport orchestration is **not yet fully removed** from ContentView:
  async download-selection and visual/lyrics side effects remain at the view
  boundary. Gradually migrate after exact parity tests. This PR is a foundation,
  not a claim of completing all five phases.
- iOS lock-screen next/previous/seek still disabled; do not turn on controls
  without end-to-end queue/remote lifecycle tests.
- Local imported files remain a distinct import path, not a persisted Track
  source; the new TrackIdentity is preparation for future gateway adapters.
- No performance, audio fidelity, visual parity or listening-quality gains
  are claimed without iPhone/Instruments measurement.
- Required before merge: backend Python unittest, XcodeGen, XCTest full
  suite, Debug + Release, unsigned IPA, changed-warning review, privacy
  and license review. Optional physical-audio fixture may skip on CI.
