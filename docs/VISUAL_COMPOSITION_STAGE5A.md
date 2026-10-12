# NightcoreLab — Stage 5A: Declarative Visual Composition

## Scope

Stage 5A introduces **only data contracts, a pure frame resolver and an
opt-in CreativeSnapshot adapter**. It does NOT introduce a shader, SwiftUI
layer, Metal renderer, animation loop, preset editor, ML model, external
dependency, audio analysis graph, or player/export wiring.

The existing `CreativePreset`, `VisualPreset`, `CreativeVisualProgram`,
`CreativeEquation`, `CreativeParameterFrame`, `CreativeSnapshot`,
`StoryRenderTimeline`, `CreativeMarbleFrameResolver`, `StorySceneView`,
and `StoryFrameRenderer` remain untouched. Existing catalog IDs:
`original`, `bass-pulse`, `night-drive`, `soft-flow`.

## Relationship to current architecture

```
CreativePresetCatalog / CreativeSnapshot
     + existing CreativeVisualProgram (typed rules)
                 |
       VisualComposition (new)
       /         |         \
 PresetLayer  AudioBinding  CompositionTimeline
       \         |         /
         CompositionFrameResolver
                 |
         ResolvedCompositionFrame (data only)
                 |
        [future explicit renderer adapter]
```

The new wrapper holds the **complete existing program**, not just a preset ID;
its serialized state therefore includes all existing audio-mapping equations.
It preserves the current user theme/typography without making new UI choices.

`CreativeSnapshotAdapter.freeze` checks that an explicitly provided program
matches the captured preset; otherwise it rejects the mismatch rather than
silently exporting a different visual. With no program, it wraps the captured
preset with no additional modulation rules. `wrap` also provides a migration
path for existing catalog programs without changing their persisted IDs.

## Typed layer model

- `PresetLayerKind`: background, artwork, typography, overlay.
- Stable nonempty layer ID; zIndex used for back-to-front order, ID as a
  deterministic tie-break. Input array order does not affect the resolved frame.
- Optional active range in **elapsed output seconds**, end-exclusive.
- `LayerProperty`: opacity, scale, normalized offsetX/offsetY, rotation
  radians and intensity. These are NOT free-form shader property strings.
  Every property has an explicit finite bound and default.
- `CompositionKeyframe`: output elapsed time, typed property, value, easing
  (hold/linear/easeInOut). The destination keyframe's easing shapes the
  segment arriving at that key. No accumulated animation state.
- `LayerAudioBinding`: a typed LayerProperty and the **existing**
  CreativeEquation. It samples the existing CreativeSignal at sourceTime
  and applies its replace/add/multiply operation to the authored/keyframed
  base value. Missing audio, silence or reaction off leaves that base value.

`VisualComposition` carries schemaVersion=1, id/name, complete
CreativeVisualProgram, layers, CompositionTimeline and deterministicSeed.
Decoding rejects unsupported schemas, duplicate layer IDs, invalid keyframes,
out-of-range property values and invalid layer clips. Invalid timestamps
cannot yield a resolved frame.

## Dual clocks and deterministic resolution

`CompositionTimeline(sourceStart, playbackSpeed, duration)` maps:

```
elapsed = output video seconds
sourceTime = sourceStart + elapsed * playbackSpeed
```

The mapping mirrors `StoryVideoRequest.sourceTime(at:)` and supports
playback speed changes without reinterpreting typography keyframes.
`CompositionFrameResolver.resolve(composition,elapsed,features:)`
computes its timestamp from the immutable composition, evaluates existing
`AudioVisualMapper` and `CreativeParameterResolver`, interpolates each
visible layer's keyframes and applies typed bindings. All work is pure and
bounded. The resolver does not use wall time, random sources, playback
position, previous frames or a new FFT. The deterministic seed is carried
through unchanged for future procedural consumers; it does not implicitly
introduce randomness.

The `ResolvedCompositionFrame` contains:
- timestamp.elapsed and timestamp.sourceTime;
- deterministicSeed and compositionID;
- `CreativeParameterFrame` from the existing visual program;
- ordered, immutable `ResolvedLayerFrame` values.

Frame resolution is intentionally **not connected to the current
StoryFrameRenderer**. Today the draft preview and MP4 already share
`StoryRenderTimeline`, `StorySceneView` and `CreativeMarbleFrameResolver`.
Integrating this composition layer into those consumers requires a separate
review/approval to avoid any accidental visual change.

## Complexity, bounds and risks

- Max 32 layers, 256 keyframes and 16 bindings per layer.
- Current resolver sorts per-layer keyframes for each property; worst case
  O(L * P * K log K) per requested frame with bounded L/P/K, no new
  rendering GPU pass and **no work unless explicitly called**.
- Future high-frame-rate integrations should pre-index immutable per-property
  keyframes during snapshot preparation, or cache that index outside this
  pure resolver; avoid adding hidden mutable frame state.
- Frozen AudioFeatures must be sampled by the future caller at the matching
  sourceTime. Stage 5A does not fetch or verify an audio asset itself.
- The seed guarantees stable identification for future procedural effects;
  it does NOT imply a seeded effect exists today.
- These contracts do not yet provide true visible typography, particles,
  shader overlays, media loading or compositing.
- Layer property bounds and allowed kinds intentionally limit the current
  representational surface; expanding them requires schema evaluation.

## Tests

The new VisualCompositionTests covers:
1. JSON roundtrip and current program/rule preservation (all four presets).
2. Unsupported schemas and unknown/free-form properties rejected.
3. zIndex / ID deterministic ordering independent of author array order.
4. Missing/silent audio means neutral CreativeParameterFrame.
5. Repeated source + output time produces the identical resolved data frame.
6. Source clock changes with playback speed; output-time keyframes do not.
7. linear/easeInOut/hold interpolation and exact target keyframe timestamps.
8. Typed audio equations, reaction off and null-audio fallback.
9. Half-open clips, duplicate IDs and invalid clip bounds.
10. Existing CreativeParameterResolver identical for the four presets.
11. CreativeSnapshotAdapter freezes the full program and rejects mismatches.
12. Invalid time mappings and duplicate property/time keys are rejected.

Run the existing GitHub Actions iOS workflow: XcodeGen generation,
XCTest in simulator, Release build and unsigned IPA. No direct graphics
performance or FPS improvements are claimed for these inactive contracts.
