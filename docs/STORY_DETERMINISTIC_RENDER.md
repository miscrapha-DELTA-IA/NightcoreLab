# Creative Engine — deterministic Story render (Swift Render concepts)

Reference: https://github.com/skyblanket/swift-render
Concept adopted: **scene = f(immutable snapshot, integer presentation frame)**.
The upstream SwiftRender package declares macOS 14+; it is **not** an iOS
dependency of NightcoreLab. Implementation below is independent SwiftUI,
Metal shader already present, and AVFoundation.

## Shared render contract

```text
ShareButton → freeze StoryVideoRequest + DSP source + StoryEncodingProfile
                 │
                 ▼
StoryDraftPreview (before expensive export)
  ├── load cover once (ShareRenderer.loadArtwork)
  ├── StoryRenderTimeline.frame(at: slider time)
  └── StorySceneView(request, artwork, frame)
                 │ confirm
                 ▼
StoryVideoExporter.export(request, same artwork, same profile)
  ├── StoryRenderTimeline.frame(index: 0...N-1)
  ├── StoryFrameRenderer → StorySceneView → ImageRenderer (MainActor)
  ├── StoryPixelWriter (worker actor, identity orientation, 1 in-flight frame)
  └── existing offline DSP audio + AVFoundation mux
                 │
                 ▼
StoryVideoPreview (playback of actual resulting MP4)
```

`StoryRenderFrame` contains:
- presentation-frame index and **exact** elapsed seconds = index / fps;
- original-file source position = start + seconds * playbackSpeed;
- LRCLIB synchronized lyric position = source + lyric offset;
- frozen Marble phase = original phase + seconds * marble speed.

The preview scrubber snaps to the **same integer frame grid** as the MP4.
The profile is frozen when the user opens the preview; toggling Low Power
Mode while reviewing cannot silently change its resolution/FPS.

### Invariants

- No `TimelineView` or wall-clock animation during Story rendering.
- Never re-fetch artwork after preview confirmation, including failed artwork
  lookups (nil falls back to the same placeholder in video).
- UI preview is visual-only. Final MP4, when requested, includes the
  previously captured source and DSP settings.
- Original player, karaoke timing and shaders are not modified.
- No second AVAudioEngine. Cancellation still stops per-frame encoding.
- Portrait frame buffers and identity transform retain existing orientation
  correction.
- Existing video playback preview remains available after MP4 completion.
- Preview is the same **composition and timeline** as the video; a compressed
  H.264 frame can differ slightly in pixels from SwiftUI's live preview.

## Validation and limits

- StoryRenderTimelineTests: integer frames, source time and speed, lyric
  offset, Marble phase, end clamp, deterministic scene raster size.
- StoryVideoTests: portrait H.264 encode/decode top/bottom color orientation.
- No claim that this uses the SwiftRender engine, nor that arbitrary Apple
  share targets (including YouTube Shorts) accept MP4 automatically.
- Hardware GPU/performance and exact Metal color accuracy must still be
  validated on a real iPhone.
