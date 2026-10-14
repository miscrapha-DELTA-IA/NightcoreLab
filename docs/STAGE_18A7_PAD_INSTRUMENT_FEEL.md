# Stage 18A.7 — Pad Instrument Feel

**Base:** `stage-18a6-pad-touch-delivery`, PR #58, commit
`0215979779a8bc52b434528cdefb25c154d7b5f3`.
The GitHub API showed PR #58 still OPEN/DRAFT at implementation time,
despite the report that it was merged. This stage is therefore stacked
on its validated branch, not merged to `main`.

## Architecture retained

- One live `AVAudioEngine`, owned exclusively by `AudioEngineManager`.
- Existing `PadVoiceAllocator` with 12 musical voices, existing buffer
  preload, kit identities, `chokeGroup` definitions and sample data.
- No changes to `EnginePlaybackClock`, `CompositionRuntime`,
  `PerformanceTimeline`/PadEvent Codable schema, or music DSP.
- Additional **eight preconnected release-only AVAudioPlayerNodes** use
  small (384-frame / 8ms / 48kHz) stereo buffers allocated at setup, NOT
  a second engine. A release lane never counts as an additional musical
  voice.

## Voice policy and micro-release

- When there are free/expired musical voices, a new hit gets a different
  slot; **no unconditional `node.stop()` on a free voice**.
- At pool exhaustion, the oldest active voice is selected (existing
  allocator policy). Before stopping that node, the app fills a fixed
  8ms buffer with the *estimated* continuation of the outgoing PCM
  waveform at its wall-clock offset and a squared release envelope.
  This release begins on a separate preconnected node.
- The existing `hat` chokeGroup remains exclusive; interruptions
  release rather than hard-cut both hats. Kick/snare/clap/808 remain
  unchoked; their earlier voices can ring until full polyphony.
- Emergency release buffers are never overwritten until CoreAudio's
  `.dataConsumed` callback releases the slot. If all eight lanes are
  still busy, a rare immediate cut is allowed **instead of racing
  the render thread**. No per-hit buffer allocation or disk I/O.
- This is a *bounded click mitigation*, NOT sample-accurate matching to
  the DAC. Existing report showed `node.play()` p95 around 22–23ms.
  Extra release scheduling may itself increase main-thread command time;
  repeat the latency probe on the iPhone, including rapid hat rolls.
- The offline `PerformancePadMixdown` scheduler keeps the original
  cut frame as `endFrame` and stores the extra release duration
  separately. Its chunked writer continues to the release end with
  the same squared envelope. Playback/export intent remains tied to
  the existing PadEvent order and velocity.

## Expressiveness, haptics, touch resilience

- Pad touch surfaces are real UIKit `UIControl` subclasses retaining
  **per-`UITouch` identity**. When one finger lifts or is cancelled,
  the other finger's pressed state stays active. View removal resets
  the entire set; no release-to-fire `Button`.
- Each pad receives a deterministic velocity curve using the finger's
  **vertical strike zone**, a clean default when bounds are unknown,
  and a fixed four-hit micro-accent sequence. The computed velocity
  is stored in the existing `PadEvent.velocity`, so offline render
  receives the identical control value. Force/pressure is NOT inferred:
  iPhone majorRadius is not a trustworthy force measurement.
- One pre-created `UIImpactFeedbackGenerator(style: .rigid)` per
  touch Coordinator. Haptics are opt-in and submitted **after the
  audio command**. No network or haptic creation on each tap.
- SwiftUI `.defersSystemGestures(on: .all)` requests that iOS defer
  edge gestures in Performance Mode; iOS retains final control.
  Touch cancellation is always handled. Do not promise Home/Control
  Center gestures can be completely disabled.
- UIKit hits are dispatched before updating `heldPads`; SwiftUI
  recomposition remains after audio submission.

## Recorded-pad output latency

- Cache `AVAudioSession.outputLatency` on Performance Mode entry
  and route change, clamped to 0–350ms. When a recording is actually
  running against music, `AudioEngineManager.recordedPadSourceTime()`
  reports `max(0, currentMediaTime - latency × speed)`.
- Do not read the session on the pad hit, do not apply the correction
  to wall-clock event timestamp, and do not double-subtract it from
  `EnginePlaybackClock.lyricTime` (already output-latency adjusted).
- This is a model-based headphone alignment correction. The final
  musical alignment depends on route and actual user monitoring
  conditions, and **must be verified on hardware** with a metronome
  / tap-versus-export A/B. Bluetooth pipeline latency is not
  automatically measurable from software alone.

## Acceptance gates
1. XcodeGen, Debug build, **all** XCTest suites — in particular
   `AudioQualityTests`, `PerformanceRegressionTests`,
   `RuntimeStabilizationTests`, pad offline/export tests and
   `PadInstrumentFeelTests`.
2. Release build / unsigned IPA and playback/backend regression.
3. Device: 16th-note rolls at 120–160 BPM, 2–4 simultaneous fingers,
   repeated same-pad attacks, open→closed hats, source clip + drums.
4. Inspect clicks/tails and polyphony; verify no stuck pressed pads
   during finger lifts/system cancellation and no regressions after
   closing Performance Mode.
5. Compare `UIKit event→handler`, `touch→command`,
   `node.play` p50/p95 before/after with capture on/off, same
   output route. Test internal iPhone speaker and Bluetooth
   **separately**. Evaluate CPU, thermal and battery impact.
6. Live sound and offline M4A A/B with controlled source music.

Do NOT mark physical fingerdrumming feel as validated based only on CI.
