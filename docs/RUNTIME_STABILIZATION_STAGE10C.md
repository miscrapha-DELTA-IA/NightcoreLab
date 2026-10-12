# Stage 10C — Performance & Runtime Stabilization

Goal: remove avoidable work before adding visual complexity. Every change is
output-identical to the code it replaces; nothing here changes pixels.

## Changes
| Audit item | Change | Where |
|---|---|---|
| C1 | Live Marble distortion moved from `@State` on `NowPlayingScreen` to an `@Observable` `CreativeLiveUniforms`, read only inside `LiveMarbleDistortion` leaves. The 12 Hz reactive loop no longer re-evaluates the whole screen body. Share freeze/unfreeze moved into the model. | `Creative/CreativeLiveUniforms.swift`, `NowPlayingScreen.swift` |
| C3 | `CompositionRuntime` compiles the composition once (`CompiledComposition`: ordered layers, keyframe tracks per property, binding index, one validation). The per-frame path no longer revalidates, sorts layers, or filters/sorts keyframes. `CompositionFrameResolver.resolve(_:elapsed:features:)` is kept for source compatibility. | `VisualComposition/CompositionFrameResolver.swift`, `CompositionRuntime.swift` |
| C3 | `StoryRequestBuilder` freezes ONE `compositionRuntime` and `preparedLyrics` into the request; `visualComposition` is now a get/set view of it. Story preview and every exported frame reuse them. | `Share/StoryModels.swift`, `StoryDraftPreview.swift` |
| C3 | `StorySceneView` resolves the composition and typography once in `init` (they were computed properties evaluated several times per body, each recompiling). | `Share/StorySceneView.swift` |
| C3 | `TypographyLayer` carries an optional `TypographyPreparedLine`; the Story path no longer rebuilds per-word seeds every frame. | `TypographyEngine/TypographyLayer.swift` |
| C4 | `AssetIdentityCache`: full-file SHA-256 only when the file's stamp (size, mtime, inode) changed. One analysis request hashed the file 2× on a cache hit and 3× on a miss. | `MusicIntelligence/AudioAssetDescriptor.swift`, `MusicIntelligenceEngine.swift` |
| C7 | `EnginePlaybackClock` caches `outputLatency`, refreshed on play and on every route change, instead of reading `AVAudioSession` on each `lyricTime` query. | `EnginePlaybackClock.swift`, `AudioEngineManager.swift` |
| Measure | `OSSignposter` intervals "Story frame render" / "Story frame encode" (subsystem `com.nightcorelab.app`, category `StoryExport`). | `Share/StoryVideoExporter.swift` |

## Not changed on purpose (needs a device to decide)
- The fixed 15 ms sleep per exported frame (≈ 4.5 s per 300 frames). It
  exists to keep the main thread responsive during export; replacing it
  without measuring touch latency could make the UI stutter.
- Pre-rendering the static Story background blur. It would require the
  preview to use the same pre-rendered image to stay pixel-identical.
- Pixel format BGRA for the encoder.
- Interpolating the 12 Hz feature envelope (it changes visuals).

## How to verify on an iPhone
1. **Instruments → Time Profiler + Points of Interest**: export a 15 s Story;
   compare "Story frame render" vs "Story frame encode" intervals.
2. **Instruments → SwiftUI** (View Body): with audio reaction on, the
   `NowPlayingScreen` body count should no longer track the 12 Hz loop; only
   `LiveMarbleDistortion` should update.
3. **Instruments → Metal System Trace / GPU**: Marble frame time at 60 and
   30 fps (`maxFPS`) on the target devices; this stage does not change the
   shader.
4. **XCTest performance**: `RuntimeStabilizationTests` reports
   `CompositionRuntime` (compiled) vs the legacy resolver for 1 000 frames,
   and Story scene resolution for 300 frames. Run on device for real numbers.

## Tests
`RuntimeStabilizationTests`: compiled runtime equals a verbatim copy of the
pre-10C resolver over 600 timestamps × 3 generated compositions (all easings,
unsorted keyframes, clips, bindings, zIndex ties, nil/silent/varied audio);
frozen Story runtime and prepared lyrics give the same frames as uncached
resolution; live uniform freeze semantics; identity cache equals a full read
and detects a rewritten file; performance baselines.
