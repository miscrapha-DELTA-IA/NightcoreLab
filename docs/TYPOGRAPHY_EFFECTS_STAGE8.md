# Stage 8 — Typography Effects Engine

## Scope and architecture

```
TimedLyricLine / WordSync + LyricsState
       TypographyPreset + original-source lyricTime
                  AudioFeatures? (frozen)
                       |
             TypographyResolver (pure)
                       |
             TypographyFrame (word fill + seeds)
                       |
        TypographyAnimationEngine (pure)
                       |
       TypographyFrame.animations[wordID]
                       |
             ResolvedCompositionFrame.typographyFrame
                /                      \
      live KaraokeWordView          StorySceneView
                                    /         \
                               preview       export
```

No new audio graph, decoder, FFT, shader, external font, AI model, timer,
preset cloud service or rendering engine has been introduced. The same
`TypographyResolver` is used by the already-shared CompositionRuntime
for the preview and the StoryFrameRenderer's scene. The Stage 7 creative
package and existing creative presets are not modified or activated.

## New contracts

- `TypographyAnimationState`: immutable per-word, bounded values for
  opacity, scale, degree rotation, normalized movement, blur radius,
  relative glow, color shift, chromatic offset (future RGB split), flicker
  delta, and effect intensity. The Magazine paper tone and active-fill
  decision are calculated here for compatibility with the old view.
- `TypographyEffectStyle`: neon, magazineCutout, glitch, kinetic, minimal
  (maps 1:1 to existing TypographyStyle).
- `TypographyAudioMapping`: typed beat/bass/energy signals and
  scale/glow/movement targets, with bounded gains. No strings or runtime
  expressions. `TypographyPreset.audioReaction` is the **master off
  switch**, disabled for all existing presets by default.
- `TypographyPreset`: additive effectIntensity, optional audioMapping and
  deterministicSeed; old JSON containing only style+audioReaction decodes
  with legacy-safe defaults. Missing/new values do not cause crashes.
- `TypographyFrame.animations`: per-word resolved effects, created by
  `TypographyResolver` via `TypographyAnimationEngine`. Existing word
  progress/seeds/magazine appearances are unchanged.

## Legacy pixel compatibility

Neon defaults to no transform, original fill, original 10pt shadow and
active-line emphasis. The KaraokeWordView's exact glyph, mask and shadow
path remains selected when the effect transform is neutral; no identity
modifier is inserted. Magazine's FNV-1a hash remains the same and
zero intensity produces exactly the old rotation, tile tone, active mask,
scale and opacity. New values only apply when deliberately authored.

The old KaraokeTypographyStyle menu intentionally still exposes only
Neon and Magazine Cutout. Glitch/Kinetic/Minimal are **engine-resolved
contracts**, available to a future explicitly approved UI/preset selector.
The existing StoryLyricTypography renderer likewise retains its existing
visual typefaces and transition behavior: it transports the same animation
state inside ResolvedCompositionFrame, but does not yet render RGB split
or other unsupported new effects.

## Deterministic rules

No Date, UUID, Double.random or state accumulated from previous frames.
Word identity uses the existing stable FNV-1a hash of
`lineID:wordID:wordText`. Procedural variation mixes this hash with
the preset's deterministicSeed, then samples fixed 12Hz timestamp
buckets using a stable UInt64 mixing function.

All features use original source-media lyricTime, including playback-speed
mapping. The result is independent of the order in which frames are asked
for, rendering FPS, player state, or wall time.

- Neon: baseline identity transform + opt-in beat scale and energy/bass
  glow using the existing 4%, 18%, 7% Stage 6 rules.
- Magazine: baseline paper tone/rotation/fill/scale/opacity are identical.
  Optional intensity adds bounded additional tilt/scale/displacement.
- Glitch: bounded horizontal offset (<= 0.045 normalized), flicker
  (<= 0.18 delta) and chromatic separation metadata (<= 0.015 normalized).
  No RGB compositor/shader is added in this stage.
- Kinetic: deterministic 160ms word-entry envelope, scale and movement.
  Optional bass/energy -> movement and beat -> scale.
- Minimal: restrained intensity <= 0.1 and no displacement/blur.
- Missing audio and reaction-off: audio modulation is zero; timing,
  lyric fill, seeds and composition do not change.

Bounds and finite checks are expressed directly in the state and mapping
contracts. The current view uses already-resolved transforms; it does
not generate effects or audio-dependent keyframes.

## Modified/added files

Created in `Creative/TypographyEngine/`:
`TypographyAnimationState.swift`, `TypographyAudioMapping.swift`,
`TypographyAnimationEngine.swift`.

Modified:
`TypographyPreset.swift`, `TypographyFrame.swift`,
`TypographyResolver.swift`, `KaraokeLyricsView.swift`.

Added: `NightcoreLabTests/TypographyAnimationEngineTests.swift`;
this document.

CompositionRuntime, StoryFrameRenderer, StorySceneView, export pipeline,
AudioEngineManager, all shaders and current catalog presets are unchanged.

## Tests and performance risks

The tests cover all five styles, deterministic out-of-order frame seeking,
seed changes, audio beat isolation, Neon defaults, Magazine paper-palette
parity, bounded RGB/flicker metadata, opt-in mapping, legacy preset JSON,
minimal intensity and identical preview/export animation state.
UIKit snapshot tests compare the old and resolved live word rendering
for both existing styles at default intensity.

The engine only maps the words in the current line (O(words)). Stable
identity is prepared once per Karaoke line via TypographyPreparedLine.
There are no new IO calls, models, FFT or background workers.
The 12Hz procedural noise is **time-domain sampling**, not an audio
analysis frequency. If future designs require sub-frame temporal
dynamics, revisit the quantization carefully so video seeks remain
reproducible.

Known limits: glitch chromaticOffset/colorShift are data only until an
approved RGB renderer exists; Karaoke's style selector has not been
expanded. Live KaraokeWordView continues using the same PlaybackClock
and scrolling behavior. Future engine-driven typography layout, kinetic
per-letter geometry and font changes should be separate stages.
