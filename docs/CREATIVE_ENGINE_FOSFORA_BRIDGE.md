# Creative Engine — Fosfora-inspired audio/visual bridge

Reference: https://github.com/kevinraymond/fosfora
Architecture patterns, not copied Rust code. License checked (Apache-2.0).
Fosfora's docs describe a bounded drop-oldest queue, drain-to-newest rendering,
beat pulse sequence counters, and typed bindings.

## NightcoreLab implementation

```text
Existing AVAudioEngine + EnginePlaybackClock
      | read-only file URL / original source-time
      v
AudioFeatureEngine [actor] --- AudioFeatureAnalyzer [Task.detached(.utility)]
      |                            produces indexed ~12 Hz audio feature timeline
      | bounded event sampling
      v
AudioVisualMapper [pure] --- CreativePreset.AudioReaction [off/subtle/responsive]
      |
      +-- CreativeVisualBindings [typed, bounded]
      |       playerGlow | marbleDistortion | lyricKinetics | particleEmission
      |
      +-- CreativeReactiveAccent [SwiftUI opt-in, visible card only]
              thin glow stroke, no shader or particle modifications

Future live analyzers can publish to AudioVisualFrameBus [actor]:
  newest features overwrite stale frames (capacity 4)
  beatSequence counts onsets even across discarded feature packets
```

### Runtime contract

- AudioFeatureEngine is **NOT** coupled to the audio rendering callback.
- The existing audio graph remains unchanged; AudioEngineManager exposes only
  a read-only local file URL to this optional feature.
- The analysis runs only after opting in at **ÁUDIO → RITMO VISUAL**. Off is the
  persisted default. Modes Suave and Reativo reuse CreativePreset.
- Full local-file decode is at most 20 minutes (existing Block 2 limit).
  The analyzed timeline is retained for the same URL across foreground
  reappearances rather than decoded repeatedly.
- The visual consumer pulls at <=12 Hz and falls back to ~2.2 Hz while paused.
  It is cancelled on disappearance, mode change, track change or app background.
- Low Power Mode and Reduce Motion disable the visual reaction completely.
- No effect is activated in karaoke, export, or Metal shaders by this stage.
- An onset is a coarse energy heuristic, **not measured BPM**.
- Beat latching: AudioFeatureTimeline.beatCount(after:through:) protects
  onsets when sampling is slower than the analysis cadence; large forward seeks
  skip old pulses. AudioVisualFrameBus exposes monotonic beatSequence for any
  future real-time producer.
- Visual bindings are typed; preset off maps to neutral. No external preset
  can execute arbitrary code.

### Scope of the first visual consumer

A lightweight SwiftUI stroke around the player reacts to glow strength.
The effect is intentionally small and independent of the audio route.
It is not yet reflected in the MP4 share exporter; synchronizing visual
reaction with export belongs to the deterministic export stage.

### Measurement recommended on physical device

Use Instruments -> Time Profiler / Energy Log while running Suave and Reativo,
including pauses, background transitions, rapid track changes, and Bluetooth.
Tests cover queue dropping, event retention, seek reset, typed bindings,
all-off passthrough and the existing audio feature pipeline.
