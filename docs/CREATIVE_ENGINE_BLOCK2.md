# Creative Engine — Block 2: Audio Reactive Engine

This block adds an **opt-in**, read-only bridge between a local audio file and
future visual consumers. It does not install an AVAudioEngine tap, modify the
processing graph, schedule render-loop timers, or change the current UI.

## Reused contracts

- `AudioEngineManager`: still owns the original playback graph and source URL.
- `EnginePlaybackClock.lyricTime`: authoritative *source-media* clock, also used
  by karaoke. No change needed for speed/pitch.
- `AudioFeatures` and `AudioFeatureEngine`: created by Creative Engine Block 1.
- `CreativePreset.AudioReaction`: off/subtle/responsive.
- `VisualPreset`, `AppTheme`, `KaraokeTypographyStyle`, `MarbleTheme`:
  unchanged. `Shaders.metal` remains untouched.

## Flow (activated only by a future consumer)

```
local audio URL (same file loaded by AudioEngineManager)
    -> AudioFeatureEngine.prepareAudio(at:)
      -> detached .utility AudioFeatureAnalyzer (AVAudioFile read only)
        -> source-time AudioFeatureTimeline (12 Hz)
          -> AudioFeatureEngine.features(at: playbackClock.lyricTime)
            -> AudioVisualMapper.map(features:preset:)
              -> VisualResponse [NO UI connected in Block 2]
```

To consume the contract later:

```swift
let featureEngine = AudioFeatureEngine()
try await featureEngine.prepareAudio(at: localMediaURL)

// Called only while visible, not inside audio callbacks:
if let response = await featureEngine.visualResponse(
    at: clock.lyricTime, preset: creativePreset,
    isPlaying: clock.isPlaying
) {
    // Future typography / shader / particle adapter.
}
await featureEngine.reset() // on track replacement, disappearance or teardown
```

The mapper is pure and can also map explicit `AudioFeatureFrame` input.
`AudioFeatureEngine.accept` remains available for that future input.

## Audio characteristics / limitations

- Band levels are approximate RMS envelopes from inexpensive lowpass/split
  filters (180 Hz and 2.2 kHz), not an FFT frequency spectrogram.
- `beatDetected` is an energy-onset heuristic with a 230 ms refractory window,
  **not** a BPM measurement. Silent audio yields a neutral response.
- File decoding is separate from playback, and is limited to the first
  20 minutes to bound work. Outside the analyzed duration returns silence.
- The envelopes reflect the **original file**. Post-EQ, reverb, pitch and limiter
  changes in live playback are intentionally not measured in this block.
- The engine does not start automatically, attach taps, or publish SwiftUI state.
  The output gate caps future pulls at 12 Hz (6 Hz in Low Power Mode).
- Cancelling analysis or replacing tracks invalidates pending results.
- `CreativePreset.AudioReaction.off` always maps to `VisualResponse.neutral`.
- The current UI and sharing/export pipelines are unchanged.

## Future blocks

Block 3 can read `wordAnimationIntensity`, Block 4 can read
`distortionAmount`/`emissionRate`, and Block 5 can render against an
offline source-time timeline without scheduling live audio.
