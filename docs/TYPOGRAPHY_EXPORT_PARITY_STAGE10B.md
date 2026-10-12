# Stage 10B — Typography Export Parity

## Problem
The live karaoke resolved lyrics with the user's effect (`karaokeTypography`)
and font (`story.lyricTypography`), but the Story always used
`TypographyPreset(style: .neon)` and its own word drawing, discarding
`TypographyAnimationState`. The Story preview matched the MP4; both differed
from the app.

## What changed
- **One effect vocabulary.** `KaraokeTypographyStyle` and the internal
  `TypographyEffectStyle` were removed; everything uses `TypographyStyle`
  (neon, magazineCutout, glitch, kinetic, minimal). Raw values are unchanged,
  so `@AppStorage("karaokeTypography")` and encoded `CreativePreset`s decode.
- **Font is a separate axis.** `StoryLyricTypography` became `TypographyFont`
  (same cases, raw values and storage key) and is now `TypographyPreset.font`
  (`decodeIfPresent`, default `.classic`; no schema bump). Magazine Cutout keeps
  its per-word fonts, which take precedence, as in the app.
- **One preset helper.** `TypographyPreset.current(style:font:)` is used by the
  live karaoke and frozen by `StoryRequestBuilder` into
  `StoryVideoRequest.typographyPreset`.
- **No silent Neon.** `TypographyLayer.forStory` requires the preset.
- **One word renderer.** `StoryLyricLine` draws a resolved `TypographyFrame`
  with `KaraokeWordView`; it no longer decides fill, style or animation. The
  renderer gained appearance-only inputs (`tracking`, `glowRadius`,
  `minimumScaleFactor`) whose defaults keep the karaoke pixels unchanged.
- **Typography without a reactive composition.** `StorySceneView.typographyFrame`
  resolves the line even when audio reaction is off (previously the Story only
  got a resolved frame when a `VisualComposition` existed).
- **Pickers** list all five styles; the share-menu font picker is now
  "Fonte das letras" because it also changes the karaoke.
- **No lossy package projection.** `TypographyPreset(legacy:)`/`legacyStyle`
  were removed. Packages store the real style; packages authored before 10B
  (which recorded glitch/kinetic/minimal as `.neon`) still validate.

## Parity definition
Same `TypographyFrame` (fill, per-word `TypographyAnimationState`, Magazine
appearance, font) for the same preset and lyric timestamp, drawn by the same
renderer. Perceived motion can differ: the export samples at 20 fps (15 in
economy) while glitch noise ticks at 12 Hz and the kinetic entrance lasts
160 ms.

## Known limitations
- Typography audio reaction stays off in app and Story (the app resolves with
  `features: nil`).
- `KaraokeWordView` does not draw `colorShift`/`chromaticOffset`; glitch is
  jitter + flicker only, identically in app and MP4.
- `KaraokeWordStyleResolver` duplicates `TypographyPreparedLine`'s hash; kept
  for its existing tests, candidate for 10C.

## Tests
`TypographyExportParityTests`: storage/Codable compatibility, font/style
round-trip, extended styles surviving packages, pre-10B packages still
validating, Story preset freezing, app-vs-Story `TypographyFrame` equality for
5 styles × 2 fonts × (with/without composition) over 80 frames, preview vs
export agreement, and a pixel check that Magazine Cutout reaches the exported
frame.
