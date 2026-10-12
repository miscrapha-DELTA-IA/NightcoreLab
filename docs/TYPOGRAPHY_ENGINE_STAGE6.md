# NightcoreLab — Stage 6: Typography Engine Foundation

## Audit and scope

**Current behavior retained:** `LyricsStore` continues parsing LRCLIB/LRC and tracking
active lines. `PlaybackClock.lyricTime` is the ORIGINAL source-media time and
`LyricsStore.userOffset` remains the user's calibration. `WordSync.progress(at:)`
supplies exact word fill; line-precision lyrics intentionally fill the whole
active line rather than inventing word timings. The CADisplayLink tracks line
changes while only the active word-synchronized row uses a TimelineView.

Legacy `KaraokeTypographyStyle.neon` uses the exact existing SwiftUI
glyph/mask/shadow layout. `magazineCutout` uses deterministic FNV-1a
appearance based on `lineID:wordID:wordText`, a fixed palette of three fonts
and three paper tones, and no random number generator.

The Story renderer has a separate `StoryLyricTypography` selector
(classic/neon/mono/cinematic/typewriter) and a different visual layout.
Stage 6 does NOT conflate that selector with Karaoke typography or change its
font, color, layer order, shadow, word spacing or animations.

## Newly added contracts (Creative/TypographyEngine)

- `TypographyPreset` — `neon` and `magazineCutout` are current styles;
  `glitch`, `kinetic`, `minimal` reserve IDs only. Typed opt-in audio response
  defaults **off**; no visual changes to current karaoke presets.
- `TypographyLayer` — a typed bridge from `LyricsState` (line, status) and
  original-source lyric offset into an existing `PresetLayer.kind == .typography`.
- `TypographyWordFrame` and `TypographyFrame` — immutable, Sendable:
  word identity, progress, stable seed, scale, glow strength, magazine variant,
  active word and line status.
- `TypographyPreparedLine` — immutable, calculated once per Karaoke line
  view to avoid hashing on word-fill frames.
- `TypographyResolver` — a pure function of state, lyric timestamp, optional
  audio features, and TypographyPreset. Uses the **same** FNV algorithm,
  rotations, fonts and tones as KaraokeWordStyleResolver, not a second visual
  randomizer.

When opted in, an onset/beat modulates only scale (+4% at full reaction).
Energy/bass modulate only glow strength (max +0.25 at full reaction).
The resolver never alters synchronization, colors or magazine selection.
These reaction outputs are **not** applied to existing views in Stage 6;
they are explicit typed contracts for a future approved renderer binding.

## Integration into composition

```
LyricsStore / TimedLyricLine / WordSync
          └─ LyricsState + TypographyPreset
             └─ TypographyResolver (pure)
                └─ TypographyFrame
VisualComposition/PresetLayer(.typography)
  └─ CompositionRuntime.frame(at:audioTimeline:typography:)
     └─ ResolvedCompositionFrame.typographyFrame (optional)
          └─ Existing StorySceneView / StoryLyricLine
          └─ Existing KaraokeLineView / KaraokeWordView
```

`CompositionRuntime` evaluates typography **only** when the requested
composition has an active matching typography layer. It applies the lyric
offset to sourceTime, not to video elapsed; the existing audio features
remain the frozen, cached sample at sourceTime. No analysis or renderer is
instantiated.

`StoryDraftPreview` attaches the active line using
`TypographyLayer.forStory`; export's unchanged `StoryFrameRenderer`
instantiates the **same** `StorySceneView`, which derives the same optional
TypographyFrame from the same `CompositionRuntime` and frame-grid timestamp.
Its `StoryLyricLine` draws word progress from the resolved frame, falling
back to original WordSync logic for non-reactive/legacy requests. No output
video format is changed.

`KaraokeLineView` now asks `TypographyResolver` for its word-fill frames.
`KaraokeWordView` remains the same rendering surface, with unchanged glyph,
paper tile, mask and shadow. Active rows continue to use the existing
TimelineView and PlaybackClock; scroll and focus UI are still view concerns,
not moved to the typography engine.

## Time and deterministic identity

- Word positions and lyric offset: ORIGINAL source audio seconds, unaffected
  by playbackSpeed mapping from video elapsed to sourceTime.
- Preview/export clock: `StoryRenderTimeline` still selects the frame index;
  `CompositionRuntime` and `TypographyResolver` have no mutable history.
- Hash: FNV-1a 64-bit over `lineID:word.id:word.text` (the same source string
  as legacy), avoiding Swift's process-randomized `Hasher`, Date and
  Double.random().
- Missing, silent or unrequested audio: typography's base scale/glow and
  lyrics timing are unchanged. Energy/beat modulation is opt-in.
- The resolved typography is optional, and does not affect shader values
  or the Marble composition state.

## Files added/modified

Added:
- `NightcoreLab/Sources/Creative/TypographyEngine/TypographyPreset.swift`
- `.../TypographyLayer.swift`
- `.../TypographyFrame.swift`
- `.../TypographyResolver.swift`
- `NightcoreLabTests/TypographyEngineTests.swift`
- `docs/TYPOGRAPHY_ENGINE_STAGE6.md`

Modified:
- `NightcoreLab/Sources/KaraokeLyricsView.swift` (active line frames)
- `NightcoreLab/Sources/Creative/VisualComposition/ResolvedCompositionFrame.swift`
- `NightcoreLab/Sources/Creative/VisualComposition/CompositionFrameResolver.swift`
- `NightcoreLab/Sources/Creative/VisualComposition/CompositionRuntime.swift`
- `NightcoreLab/Sources/Share/StoryDraftPreview.swift`
- `NightcoreLab/Sources/Share/StorySceneView.swift`

Unchanged: AudioEngineManager, KaraokeWordView's drawing implementation,
StoryFrameRenderer, StoryVideoExporter, Marble renderer/shaders, queue,
lyrics parsing/networking, current theme font assets, and CreativePresetCatalog.

## Cost, tests, risks

The live active line precomputes identity/magazine descriptors once per
row view. The pure resolver maps only the visible row's words at the current
source time and has O(words in active row) complexity, without FFT, new
CADisplayLink, external assets, or asynchronous background work. Story
resolves one active line per exported frame.

Tests cover stable identity, determinism, legacy magazine appearance parity,
word vs line precision, preset switching, silent/default opt-out, typed
beat/energy reactions, active typography-layer bridging, and identical
preview/export TypographyFrame at the same timestamp. The previous
KaraokeTypographyTests Neon pixel-equality and 17-theme contrast regression
tests also remain in the full XCTest suite.

Risks/limits: FNV collisions are theoretically possible; keying by both
line/word/text is much safer than ID alone. The future glitch/kinetic/minimal
styles are reserved values with no dedicated renderers, and reactive scale/
glow are data only. Future fully declarative multitrack typography or
cross-line animation should be a separate feature, not silently enabled
during the Foundation stage.
