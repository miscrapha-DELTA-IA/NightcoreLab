# Stage 12 — Visual Material Engine (first cut: rhythmic Marble)

Agreed scope: the material model and its audio/rhythm → uniform mapping, with
only the existing Marble migrated, using `RhythmFrame` (Stage 11) for a beat
pulse. Same shader for live, Story preview and MP4. Liquid Glass, Chrome and
fluid materials are out of this cut.

## Model
- `VisualMaterial` (Codable data): `kind` (`.marble`), `beatPulse` 0…1,
  `pulseDecay`, `offbeatScale`. `VisualMaterial.marble(for: program)` derives
  it from the existing program (reaction off → no pulse; subtle/responsive ×
  visual intensity), so no preset schema changes.
- `MaterialResolver.marble(_:parameters:rhythm:) -> MarbleUniforms` — pure:
  distortion from the existing `CreativeParameterFrame`, pulse from
  `RhythmFrame.pulse(decay:)`, weighted by rhythm confidence (fades out below
  0.75, zero below 0.25) and softened off the downbeat when downbeats are
  reliable.

## Shader
`liquidMarble` gains `float beatPulse`: it adds to the existing domain warp
and adds an accent-colored glow away from the veins. With `beatPulse = 0`
every new term is an added zero, so the look is the pre-12 Marble (Metal
fast-math could still reassociate; differences, if any, are sub-ULP).

## Wiring
| Path | Pulse source |
|---|---|
| Live player | `MarblePulseDriver` evaluated once per rendered frame inside the Marble's own `TimelineView` (`RhythmFrame.at(clock.lyricTime)`), published through `CreativeLiveUniforms` by `CreativeReactiveAccent`. The 12 Hz loop is too coarse for a ~150 ms pulse. Hidden while sharing (frozen). |
| Story preview / MP4 | `StorySceneView` resolves it from the frame's **source time** with the rhythm loaded alongside the energy timeline (`AudioFeatureEngine.analysisResult(for:)`), threaded through `StoryDraftPreview` → `StoryVideoExporter` → `StoryFrameRenderer`. |

Same function of source time everywhere: scrub preview = MP4 at any fps.
Live uses `lyricTime` (output-latency corrected) so the pulse lines up with
what is heard; the MP4 uses the source time its own audio track starts from.

## Costs and caveats
- The first analysis of a track now includes the Rhythm v2 decode before the
  live reaction starts (cached afterwards).
- Per live frame: one binary search over the beat list.
- Visual tuning (warp +18 %, glow 10 %) was set blind; it needs a look on a
  device before release.

## Tests
`VisualMaterialTests`: derivation from the reaction switch, bounds/Codable,
no pulse without reliable rhythm, downbeat accent and decay, distortion
passthrough, legacy Story has no pulse, Story pulse as a function of source
time across frame rates, preview = export, live driver = resolver at the
clock time, frozen uniforms hide the pulse.
