# Creative Engine — projectM-inspired versioned presets

Reference: https://github.com/projectM-visualizer/projectm (LGPL-2.1);
no projectM C++ code, MilkDrop parser or shader runtime is imported.

## Architecture

```
AudioFeatureEngine (same AVAudioEngine-backed source as before)
  -> AudioFeatures + sourceTime
  -> AudioVisualMapper (unchanged pure signal mapping)
  -> CreativePresetCatalog [stable ids + descriptive VisualPreset]
  -> CreativeParameterResolver [pure typed equations, schema v1]
  -> CreativeParameterFrame [playerGlow / marbleDistortion /
                             lyricKinetics / particleEmission]
  -> SwiftUI CreativeReactiveAccent [ONLY playerGlow bound in this phase]
```

`CreativeVisualProgram` wraps the existing `CreativePreset` with up to four
`CreativeParameterRule` bindings and `schemaVersion: 1`. Each binding
targets an existing `CreativeVisualTarget` and has a typed `CreativeEquation`:

- Signal: bass, mid, treble, energy, beat onset or deterministic
  timeSine(sourceTime, frequency, phase).
- Operation: replace, add, multiply relative to the existing mapped value.
- Coefficients and results are bounded, non-finite values are sanitized.
- Decoder rejects unknown schema revisions, duplicate targets and >4 rules.
- No arbitrary code, internet presets, user-supplied Metal or eval parser.
- Evaluation is stateless and depends only on features, timestamp and recipe,
  enabling future offline MP4 frames to match a live preview.

## Curated catalog

- **Original**: exact previous player border response; default
  `creativePresetID = original`.
- **Bass Pulse**: bass amplitude drives glow and describes future Marble
  distortion (not wired to shader yet).
- **Night Drive**: a restrained addition of energy to glow; records a
  prospective mid-driven lyric kinetics control.
- **Soft Flow**: deterministic slow sine modulation of the current glow.

Selecting a preset modifies *only* the opt-in visual response: current
AppTheme, karaoke typography, audio graph, GPU shader and video exporter
stay unchanged. `creativeReactionMode = off` remains the default.
Subtle scales authored replacement/addition modulation down. Silent audio,
paused playback, Reduced Motion, Low Power Mode and invisible views remain
neutral or disabled as in the Fosfora bridge.

## Integration and limitations

The UI selector lives in the existing Audio workspace ("RITMO VISUAL"),
beside Desligado/Suave/Reativo. Selection is stored as a stable built-in ID
using AppStorage. Invalid saved IDs fall back to Original without crashes.
No editor, import/export of user presets, public marketplace, full
waveform/MilkDrop evaluation, particle engine or new shader is included.

Future stages can connect the other typed outputs without putting equations
in Metal or into `View.body`. Deterministic video export should resolve a
parameter frame at the same timestamp as `StoryRenderTimeline`.

## Tests

`CreativeVisualProgramTests`: curated IDs, Codable and unknown schema,
duplicate/oversized binding rejection, finite bounds, theme preservation,
Original passthrough, nonlinear time consistency, reaction off/pause/silence,
Subtle vs Reativo, UserDefaults persistence across re-open, all 17 themes.

Physical device profiling is still needed before enabling the feature by
default. Presets remain off unless the user enables the visual reaction.
