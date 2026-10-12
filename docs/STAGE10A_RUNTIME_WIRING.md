# Etapa 10A — Runtime Wiring & Pixel Consumption

**Base audited:** d4b05d6 (12 October 2026). **PR review required. No merge.**

## Scope: old data finally reaches existing Story pixels

Nothing in Shaders.metal, AVAudioEngine, RhythmAnalyzer, the live NowPlaying
rendering, existing CreativeExperiencePreset, composition schemas, or MP4
encoder was modified. This task uses only existing composition and typography
contracts plus a pure ResolvedLayerFrame-to-Story mapping extension.

### 1. Compile once

`CompositionRuntime.init(composition:lyrics:)` compiles:
- stable layer ordering by zIndex then layer ID;
- sorted keyframe tracks grouped by `LayerProperty`, keeping incoming
  keyframe's easing and both inclusive-boundary rules;
- one binding per property, indexed by `LayerProperty`;
- stable `TypographyPreparedLine` per lyric line for the frozen Story.

`CompositionFrameResolver.resolve(_:elapsed:features:)` remains available
and delegates to a compiled runtime. Its construction cost stays visible
when calling the compatibility API repeatedly; Story stores one runtime in
`StoryVideoRequest.compositionRuntime` and reuses it every frame. The
validated `VisualComposition` no longer runs `isValid` inside evaluation.
The Story scene reads its resolved frame once per body, then passes that
same state into the background, scrim, artwork and lyrics.

### 2. Always freeze Story

`StoryRequestBuilder` freezes an effective `CreativeVisualProgram` even
when the existing reaction switch, Reduce Motion or Low Power Mode disables
audio reaction. Its `audioReaction == .off` returns neutral
`CreativeParameterFrame`, including `marbleDistortion == 0` (the exact
previous color and warp). The builder also stores the actual user's
karaokeTypography and creativePresetID passed from NowPlayingScreen.
The Story UI can now be layered and synchronized even without a reactive FFT.
Directly synthesized legacy `StoryVideoRequest` still defaults to a nil
runtime, using StorySceneView's existing fallback resolver.

The request's `visualComposition` is a backwards-compatible read-only
computed projection of `compositionRuntime?.composition` to prevent
divergent frozen models. The request remains the same immutable input for
both StoryDraftPreview and StoryFrameRenderer.

### 3. Four layer view bindings

`ResolvedLayerFrame.storyModifiers(kind:frame:)` is a pure function. A
missing layer in a nonnil frame gives opacity 0. A nil composition frame
is the direct-legacy path and returns the neutral identity transform.

| Layer kind | View actually affected |
|---|---|
| background | Existing full Story background (Marble or blurred cover) |
| overlay | Existing black 40% scrim |
| artwork | Artwork tile inside player card only |
| typography | Existing lyricsCard only |

In one unchanged ZStack, the view applies opacity, centered scale,
canvas-normalized offsetX × 540, offsetY × 960, and rotation in **radians**.
An all-identity transform does not insert any extra modifier, preserving
previous pixels. Source layer timing is in video elapsed time, never
source audio seconds.

**NOT APPLIED:** layer intensity, even if resolved; a future stage decides
its visual meaning. **zIndex does not reorder the hard-coded ZStack.**
Player card labels, transport buttons, header and footer are not layered.

### 4. Frozen Karaoke style in Story

`TypographyLayer.forStory` accepts the already frozen TypographyPreset
instead of silently forcing Neon. The TypographyResolver uses cached
TypographyPreparedLine data and emits the existing TypographyFrame and
TypographyAnimationState with deterministic word IDs. StoryLyricLine
applies per-word opacity, scale, rotation (degrees), offsets, and blur.
It consumes resolved magazine palette/tone and active-fill, reusing
`MagazineCutoutTone.background(accent:)` without introducing another
font or shader. **The original StoryLyricTypography font is preserved.**

Neon with neutral intensity bypasses all effects and preserves its exact
original Text, mask, shadow and layout code path. MagazineCutout instead
deliberately renders paper-like word tiles in the Story: this is a new
visible effect for users who selected magazineCutout; it was previously
ignored there. A later Stage 10C may unify the three typography enums.

### 5. Proofs and instrumentation

- `StoryRuntimeWiringTests` embeds the unmodified previous resolver as
  `LegacyCompositionFrameResolver`, including its original validation,
  keyframe filtering and sorting.
- Compares complete Equatable frames across **600 timestamps** plus exact
  easing/clip boundaries; fixed-seed compositions include all three
  easings, all six properties, clips, and typed audio bindings.
- Two `XCTest measure` benchmarks each run **1,000** resolutions per
  sample for legacy/compiled paths. Numbers are reported from CI (not
  assumed or fabricated).
- `StoryPixelConsumptionTests` compares **raw RGBA8 bytes** from
  `StoryFrameRenderer` against a `StorySceneView` supplied with the exact
  `StoryDraftPreview.resolveFrame` output at the matching frame index.
- Baseline direct-legacy vs frozen-default: player and lyric modes must
  be identical by pixel bytes.
- Overlay opacity 0, artwork scale 0.5, and inactive typography clip
  must visibly change the MP4 raster and produce identical preview bytes.
- MagazineCutout must change actual pixels vs Neon; Neon intensity 0
  must remain byte-identical to the old direct-request path.
- The rest of `NightcoreLabTests` must pass unchanged. `ios.yml`
  is enabled for pull_request; building a PR must **not** require main push.

### Explicit preview/MP4 parity

| Scope item | Preview equals MP4? | How verified |
|---|---|---|
| Compiled runtime | Yes | exact same compiled request runtime and frozen frame grid |
| Default composition with reaction disabled | Yes | raw pixel comparison against direct legacy, both modes |
| Layer transforms | Yes | preview/export byte comparisons for non-neutral overlay/artwork/clip |
| Typography animation | Yes | same frozen TypographyFrame, pixel comparisons Neon and Magazine |

**No claim is made that uncompressed preview bytes equal lossy H.264 decoded
pixels.** The parity tested is the CGImage produced by the *exact same*
StoryFrameRenderer frame before MP4 compression; H.264 is lossy and should
not be expected to reproduce identical RGB bytes after decoding.

### Known risks

- SwiftUI/Metal renderer can change pixel encoding across different
  hardware or OS versions; tests compare both branches in the **same**
  simulator/hardware session.
- Strict opacity 0 for missing layers is intentional only with a compiled
  composition present. The nil-frame path remains compatible.
- Background clip removal reveals the unchanged black scrim/backdrop.
- No visual zIndex hierarchy changes; no intensity binding yet.
- The builder now rejects invalid playback speeds outside the composition
  clock's already accepted 0.1x–4x interval instead of constructing a
  partially initialized Story; normal speed range is unchanged.
