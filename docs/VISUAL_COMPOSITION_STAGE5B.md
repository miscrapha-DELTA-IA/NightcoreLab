# NightcoreLab — Stage 5B: Composition Runtime Integration

## Scope and safety boundary

**The existing renderers are unchanged.** There is no new Metal shader,
SwiftUI renderer, animation clock, AVAudioEngine, FFT, preset, editor,
AI service, or dependency. This integration only activates the existing
Stage 5A declarative resolver as the source of Marble parameters inside the
**already shared StorySceneView** for both draft preview and export.

Files created:
- `Creative/VisualComposition/CompositionRuntime.swift`
- `Creative/VisualComposition/ResolvedFrameRendererAdapter.swift`
- `NightcoreLabTests/CompositionRuntimeTests.swift`

Existing files modified minimally:
- `Share/StoryModels.swift`: freeze a `VisualComposition` once during
  `StoryRequestBuilder.make` into an optional request value.
- `Share/StoryDraftPreview.swift`: request
  `CompositionRuntime.frame(at:audioTimeline:)` on the existing
  `StoryRenderTimeline` frame grid; pass its resolved frame into the scene.
- `Share/StorySceneView.swift`: accept an optional precomputed resolved
  frame, or compute it using the same runtime for export. Pass its
  `CreativeParameterFrame.marbleDistortion` to the existing
  `TurbulentMarbleView`, without changing layout, colors or shader inputs.

**Not modified:** StoryFrameRenderer, StoryVideoExporter,
CreativeMarbleFrameResolver, TurbulentMarbleView, existing shaders,
player, karaoke, queue, AudioEngineManager, all Stage 5A contracts.

## Exact data flow

```
StoryRequestBuilder
     └─ frozen CreativeVisualProgram + original sourceStart/speed/duration
         └─ VisualComposition (once per request)
                │
StoryRenderTimeline.frame(index:) / frame(at:)
                │ elapsed
                ▼
CompositionRuntime.frame(at:audioTimeline:)
   ├─ CompositionTimeline (elapsed → sourceTime)
   ├─ CompositionAudioSampler (AudioFeatureTimeline at sourceTime)
   └─ CompositionFrameResolver (Stage 5A, pure)
                │
        ResolvedCompositionFrame
                │
        ResolvedFrameRendererAdapter
                │
        Marble's EXISTING reactiveDistortion input
                │
           StorySceneView
              ├── draft preview
              └── StoryFrameRenderer → H.264/MP4 export
```

The draft preview resolves once and passes the resolved frame to the
scene; export's unchanged StoryFrameRenderer instantiates that **same**
StorySceneView, which uses the **same runtime method** to resolve the
frame. A precomputed frame is accepted only if its composition ID, seed
and dual timestamp match the scene's frozen composition and grid;
otherwise the scene resolves it again. No mutable frame accumulation
or divergent preview/export equations are introduced.

## Compatibility with the current Marble shader

Previously, `CreativeMarbleFrameResolver` sampled:
1. `AudioFeatureTimeline.features(at: sourceTime)`
2. `beatCount(after: max(0, sourceTime - 0.15), through: sourceTime)`
3. `AudioVisualMapper.map` and `CreativeParameterResolver.resolve`.

`CompositionAudioSampler` **retains the exact same first two calls**.
`CompositionFrameResolver` (Stage 5A) retains the same final two.
`ResolvedFrameRendererAdapter` returns precisely the existing
`CreativeParameterFrame`, particularly `marbleDistortion`.
No change in visual reactions or Metal uniforms is expected.

If `reactiveProgram` is nil, composition is nil and the scene uses
the unchanged no-reaction state. If an unusual request cannot be
represented by Stage 5A's validated speed/duration contract (e.g. an
out-of-range speed), `visualComposition` stays nil and the scene uses
the exact legacy `CreativeMarbleFrameResolver` compatibility path.

In both supported paths, missing, silent, out-of-coverage, or
non-finite audio inputs do not synthesize a beat: neutral modulation
is passed to the existing shader.

## Time domains

`StoryRenderTimeline` remains the source of the integer export frame
grid. The runtime maps:

```
frame.elapsed = index / exportFPS
frame.sourceTime = request.playbackTime + frame.elapsed * request.speed
```

The reactive envelope is sampled at sourceTime; keyframes remain in
elapsed seconds. The request freezes the full program and layers
before preview/export; speed, seed and program do not change during
render. The runtime uses no Date, random or previous-frame state.

## Performance and risks

- `VisualComposition` is built **once**, not per video frame.
- Cached `AudioFeatureTimeline` is reused; there is **no new audio
  analysis, FFT, decode, or AVAudioEngine**.
- No frame cache is introduced: duration is at most 15 s and current
  export profiles produce 225–300 frames. The existing Stage 5A
  resolver bounds layer count to 32 and keyframes to 256 per layer;
  present-time keyframe evaluation sorts small arrays per frame.
- The runtime does extra CPU work compared to the old direct Marble
  resolver, because it also resolves declarative layer properties
  which are **currently not rendered**. Benchmark before enabling
  large compositions or increasing output FPS; an immutable
  pre-indexed keyframe plan can later be added if justified.
- Existing StoryRenderTimeline/StoryFrameRenderer determine output
  dimensions, frame count, colors and H.264 encoding, unchanged.
- The external request may still be constructed directly by legacy
  callers; the no-composition compatibility path is intentional.
- Matching IDs/times for injected precomputed frames is a guard for
  frame-grid errors, not an authentication scheme for arbitrary
  untrusted data. The preview path constructs its own frame internally.

## Validation

CompositionRuntimeTests exercises:
- same timestamp/audio → same immutable frame after random-order seeks;
- preview supplied frame equals export auto-resolved frame on both FPS profiles;
- missing/silent/out-of-coverage audio keeps neutral values;
- playbackSpeed 0.75, 1.0, 1.5 yields correct elapsed/source clocks;
- all four current presets and three reaction modes match the legacy
  Marble resolver at numerous source timestamps;
- onset look-back reproduces the old beat-trigger semantics;
- mismatched precomputed timestamps are rejected/recomputed;
- nonreactive request preserves the original look;
- StoryFrameRenderer still produces the same sized portrait raster.

CI runs XcodeGen, simulator XCTests, unsigned Release build and IPA.
