# Stage 18A — Live Performance Pads MVP (initial release candidate)

Base: `stage-17d-karaoke-smoothness`, commit `5235299898667cb7c754ba6bbcde4ed877d2e324`.
The user reported the karaoke is smooth in device testing; all four 17D CI
workflows are green on the baseline. No earlier PR is merged into main.

## Existing audio/export ownership

The production playback owner is `AudioEngineManager` and its **one live**
`AVAudioEngine`. Existing player DSP:
music → upmix → varispeed → timePitch → bass EQ → reverb → limiter → main.
The pre-existing `renderOffline` deliberately creates an independent,
temporary AVAudioEngine for export, not a second live playback graph.

`CompositionRuntime`, `CreativeExperiencePreset`,
`StoryRenderTimeline` and `StoryVideoExporter` remain unchanged.

## MVP implementation

- Seven 100% original in-app synthesized sounds: kick, snare, closed hat,
  open hat, clap, crash, 808. Source code is the reproducible sample asset;
  no audio recordings, credentials or external license dependencies.
- `SampleDescriptor` + `PadKit` are typed and Codable. No arbitrary
  sample URL or disk file is loaded on pad touch.
- `PadSampleSynthesizer` prepares PCM buffers at engine initialization.
  A fixed pool of twelve `AVAudioPlayerNode` voices is attached to the
  **existing** live audio graph through a `performanceMixer`.
  A mixed branch joins **after** song-only speed/EQ/reverb and **before**
  the same peak limiter. Thus 0.5× song playback doesn't pitch down drums.
- `PadVoiceAllocator`: fixed polyphony, oldest-voice stealing, hat
  choke group and lease expiration. Voice nodes are stopped and reconnected
  on source replacement; standard playback and karaoke retain existing
  clock, playback intent and queue semantics.
- Performance Mode opens only on user action via a header shortcut.
  Seven large UIControl touch-down targets (independent simultaneous
  touches), optional haptics, kit identity, track-playing indicator.
  Closing the mode stops pad voices, not the music.
- `PadEvent` + `PerformanceTimeline` schema v1: finite event count,
  ordered monotonic elapsed timestamps, optional original music source
  timestamp, velocity and sample duration. Session capture in memory only.
  Recording starts/stops explicitly. An event-only JSON sequence can be
  shared using ShareLink. **Do not misrepresent JSON as mixed audio or video.**

## Release limits — not yet finished

- Real-device pad→sound latency and CPU/memory/thermal load need measured
  baseline/after results. XCTest is not an audio latency benchmark.
- The existing **video/Story exporter** remains unchanged. The existing
  `AudioEngineManager.renderOffline` now supports an optional frozen
  PerformanceTimeline. A temporary chunked pad stem is mixed via the existing
  offline graph upstream of the common limiter; normal exports do not pass it.
  Performance Mode can share the resulting M4A when a music source is loaded.
  Pad-only audio export, live FX automation and video/Story integration remain
  pending. JSON share remains an event-only option.
- Sample Picker, song slicing, loops, optional offline stem splitting,
  microphone capture, karaoke scoring and AUv3 are **not** in this MVP.
- `PanelStore` still controls the existing Player/Karaoke visibility;
  the mode opens as a separate sheet without a second app or persistent
  visibility preference. No new generic panel engine.
- Physical iPhone device testing: simultaneous fingers, Bluetooth,
  play/pause, rate 0.5–2×, route changes, safe limiter mix, interruption,
  voice stealing, thermal/Low Power, background and karaoke switching.

## CI gates

- XcodeGen + debug build; 29+ Python backend unit tests;
  full XCTest (PadEngineTests plus karaoke regressions), Release and IPA.
- No branch auto-merge; this is a stacked draft PR.
- Any failed CI must be fixed before further product features are added.

## Next bounded increments (subject to tests)

1. Run a real-device A/B test for pad→sound latency, polyphonic choke and
   pre-/post-mix limiter behavior; verify the M4A stems sound representative
   of the live kit at 44.1k and 48k sample rates.
2. Integrate a frozen performance-event projection with the *existing* Story
   renderer. Audio-only export is available; video remains unchanged.
3. Only then allow rights-safe sample slicing and loop regions. Stems, mic
   and scoring remain future work.
