# Creative Engine — Marble reactive shader / deterministic export

This increment binds the existing projectM-style `CreativeParameterFrame.marbleDistortion`
to the existing Metal `liquidMarble` shader; no new GPU pass and no new FFT
engine are introduced.

## Live path

```
AudioEngineManager.visualAnalysisURL (read-only local file)
      -> AudioFeatureEngine (one instance, owned by NowPlayingScreen)
          -> existing FFT AudioFeatureTimeline
          -> AudioVisualMapper / CreativeParameterResolver
          -> CreativeReactiveAccent (<=12 Hz; muted when paused, hidden,
                                     Reduce Motion, Low Power Mode)
          -> CreativeParameterFrame.playerGlow / marbleDistortion
          -> NowPlayingScreen
                 |- TurbulentMarbleView (single fullscreen shader)
                 |- BackgroundLayer (karaoke Marble only)
                 |- PlayerBackgroundView (turbulent card only)
```

`TurbulentMarbleView.reactiveDistortion` is opt-in and defaults to 0. The
existing Metal shader simply scales **existing** warp and swirl coefficients
by at most 28%/16%. The old colors, octave counts, and domain warp are
unchanged when the input is zero. For other background styles, the signal
is harmless and has no effect.

There is no second analyzer or polling loop: `CreativeReactiveAccent`
publishes its existing, throttled parameter frame up to the parent. Only
the values that actually change invalidate the SwiftUI composition.
`AudioFeatureEngine` is now shared with the Story preview as a reference,
so that the already decoded local-file timeline can be reused. Temporarily
frozen PNG/MP4 sharing freezes the currently displayed Marble distortion
in addition to the pre-existing phase freeze.

## Frozen Story preview / MP4

`StoryVideoRequest` optionally freezes:
- `reactiveProgram`: exact selected CreativeVisualProgram, app theme,
  karaoke style and reaction intensity at capture time.
- `reactiveSourceURL`: the same local song file loaded for playback.

`StoryDraftPreview` reuses `AudioFeatureEngine.cachedTimeline(for:)` when
possible; otherwise a detached `.utility` task performs at most one local
offline FFT analysis before enabling the **Gerar MP4** button.
If the source cannot be analyzed, BOTH preview and MP4 fall back to the
unchanged static Marble and the export still works.

`CreativeMarbleFrameResolver.resolve(program:timeline:sourceTime:)` is a
pure, deterministic function of the frozen source-time timestamp. It
samples the same 12 Hz source envelope and uses a fixed 150-ms beat-onset
window (no stateful frame-to-frame accumulation). Seeking or reviewing
frames in arbitrary order gives the same output.

`StorySceneView` is the shared rendering surface. The preview and
`StoryFrameRenderer` receive the same frozen audio timeline, scene
snapshot, and `StoryRenderFrame.sourceTime`, so the Metal uniform is
identical at each frame index, regardless of order or encoding duration.

## Safeguards

- No AVAudioEngine changes and no new third-party SDK/Metal shader.
- `reactiveDistortion == 0` reproduces the previous shader.
- `creativeReactionMode == off` (the existing default), silent audio,
  invalid timestamps, cancelled/failed audio analysis, low power at capture
  and Reduce Motion at capture all produce the old visual appearance.
- Same `StoryRenderTimeline`, fixed FPS/resolution, and existing worker
  encoder, orientation, cancellation and audio sync paths.
- No extra audio analysis **inside the per-frame MP4 loop**; only binary
  search on precomputed features and pure parameter mapping.
- Live audio event latch is based on the previous visible sample; export
  intentionally uses a stable 150-ms look-back for seek-independent frames.
  These can differ slightly at beat boundaries but the preview/MP4 pair is
  identical. GPU color compression can also produce minor differences.

## Deferred

The share-card PNG exporter has its own ShareSnapshot renderer and is not
included here. Particle and typography shader bindings remain declarative.
Native Instruments GPU/time/energy measurements are required before raising
the reaction update rate or intensity.
