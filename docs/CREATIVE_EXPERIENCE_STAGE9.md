# NightcoreLab — Stage 9: Creative Experience Preset Engine

## Audit and scope

Previous stages already supply the complete authoring hierarchy:
- `CreativePresetCatalog.program(for:)` contains **original, bass-pulse,
  night-drive and soft-flow** and their existing `CreativeVisualProgram`
  audio equations; catalog fallback/default selection remains unchanged.
- `CreativePresetPackage` (schema v1) is an authoritative, Codable, local
  authoring envelope for the visual preset, typography and complete
  `VisualComposition` (including layers, rules, keyframes and timeline).
- `CompositionRuntime` computes the same `ResolvedCompositionFrame` in
  preview and export; its existing offline audio sampler remains unchanged.
- `TypographyResolver` + `TypographyAnimationEngine` already produce
  the optional `TypographyFrame` with stable per-word animation states.

**Stage 9 adds no alternate preset editor, renderer, shader, FFT, audio graph,
cloud, marketplace, IO within the render loop or MP4 behavior changes.**
It is an opt-in authored experience wrapper above CreativePresetPackage.

## Architecture

```
CreativePresetPackage (authoritative, Codable)
 ├── CreativeVisualProgram / CreativePreset / VisualPreset
 ├── VisualComposition / PresetLayer / CompositionTimeline / keyframes
 └── TypographyPreset (Neon/Magazine/Glitch/Kinetic/Minimal)
                    |
CreativeExperiencePreset (schemaVersion 1)
 ├── package (NOT duplicated)
 ├── description
 ├── CreativeAudioMapping (explicit supplementary, opt-in)
 └── exportStyle: CreativePresetCanvasHint (metadata only)
                    |
AudioFeatures? + elapsed output timestamp + optional LyricsState
                    |
CreativeExperienceResolver (pure)
 ├── CreativeAudioMapping.resolve(features:) -> CreativeAudioState
 └── CompositionRuntime.frame(at:features:typography:)
       ├── CompositionFrameResolver (existing)
       └── TypographyResolver -> TypographyAnimationEngine (existing)
                    |
CreativeExperienceFrame
 ├── visualFrame (existing CreativeParameterFrame + authored intensity/movement)
 ├── typographyFrame (optional, identical to compositionFrame.typographyFrame)
 ├── compositionFrame (exact existing ResolvedCompositionFrame)
 └── audioState (supplementary audio targets)
                    |
         [Future opt-in render adapter]
```

`CreativeExperiencePreset.visualPreset`, `typographyPreset`, `composition`,
`name`, and `id` are **computed projections of package**; they are not
copied into independent serialized properties. This is essential to avoid
two competing versions of visual rules, typography configurations or
layer keyframes. The original package schema is not changed.

## Typed audio mapping (supplementary, not duplicate rules)

`CreativeAudioMapping` is a distinct high-level experience *envelope*
with explicit typed sources `bass, energy, beat, frequency` and targets
`visualIntensity, typographyIntensity, movement`. It never duplicates
`CreativeVisualProgram.rules`, `LayerAudioBinding`, or the Stage 8
`TypographyAudioMapping` equations. `frequency` is specifically the
normalized `AudioFeatures.treble` **band energy**, not Hz, pitch or new FFT.

The mapping defaults **disabled**. Gains are 0…1; bindings cannot repeat
a (signal,target) pair; up to 12 rules. Decoding rejects duplicates,
unrecognized enums, unsupported schemas, and invalid gains. Runtime
values are clamped 0…1 and missing audio produces neutral mapping outputs.

The existing Marble parameter frame is **never mutated** by the new
envelope. Its resolved intensity/movement supplements the view-model
for a later opt-in renderer. The typed typography intensity augments an
explicitly selected `TypographyPreset.effectIntensity` (clamped at 1)
only if a typography layer is actually supplied. All existing preview
and export consumers continue using the legacy `CreativeParameterFrame`.

## Preset authoring & migration

`CreativeExperiencePreset.fromLegacy(id)` wraps exactly the existing
`CreativePresetPackage` from Stage 7, preserving program rules,
composition seed and original visual/typography settings. Its mapping
is disabled and the same `CompositionRuntime.frame` is returned.

Catalog-only example experiences (data, NOT activated):
- **Cyber Night** (`cyber-night`): Night Drive program + typed Glitch
  typography + bass/beat/high-band emphasis. Existing Marble shader.
- **Liquid Dream** (`liquid-dream`): Soft Flow program + Magazine Cutout
  with authored but bounded movement and energy mapping.
- **Neon Pulse** (`neon-pulse`): Bass Pulse program + kinetic typography
  and beat/energy/bass mapping.

The three examples are synthesized once from existing catalog programs
and new IDs. None adds a shader, changes the `KaraokeTypographyStyle`
selector or touches `StoryVideoRequest`. Every example remains a
self-contained Codable `CreativePresetPackage` with immutable rules.

`CreativePresetCatalog.availableExperiences(from:)` reuses the existing
Stage 7 `CreativePresetPackageStore`; it shows four legacy recipes,
then curated experiences, then locally authored packages. Duplicate
visible IDs are filtered so a local package cannot override the curated
catalog entry. Persisted files are not altered.

## Clock domains and deterministic processing

- Input timestamp is `CompositionTimeline.elapsed` in output-video
  seconds. `CompositionRuntime` converts it to the ORIGINAL source
  audio time for equations and lyrics (including playback speed).
- All audio samples are supplied by the caller and must be frozen for the
  correct sourceTime. Nothing reads `AVAudioEngine`, player time or wall time.
- Keyframes remain in elapsed time, lyric timing in source time.
- Seeds come from the immutable composition/preset. No random generators,
  new UUIDs, previous frame history or global state.
- The same call supports ordered, out-of-order and repeated frame requests.

## Files created / modified

New: `CreativeAudioMapping.swift`,
`CreativeExperiencePreset.swift`, `CreativeExperienceFrame.swift`,
`CreativeExperienceResolver.swift`, `CreativeExperienceEngineTests.swift`,
and this document.

Modified:
- `CreativePresetCatalog.swift` (only new Stage 9 extension).
- `VisualComposition/CompositionRuntime.swift` (add frozen AudioFeatures
  + optional typography overload and opt-in experienceFrame helper;
  offline preview/export now forward through the SAME shared overload).

NOT modified: `CreativePresetPackage`, `CreativePreset`, `VisualPreset`,
`TypographyPreset`, `TypographyAnimationEngine`,
`ResolvedCompositionFrame`, `StorySceneView`, `StoryFrameRenderer`,
player, queue, karaoke renderer, shaders, or MP4 encoder.

## Validation, cost and risks

New XCTest coverage: strict schema and Codable round-trip, all seven
catalog experiences, existing four-program parity at multiple timestamps,
audio signal/target isolation, disabled/missing audio, bounded output,
source/playback speed mapping, repeated/out-of-order frames, cross-path
preview/export equality, local Stage 7 catalog reuse and matching runtime
guard.

No new audio decoding, GPU passes, network, model inference or frame
cache. A resolved experience adds O(N) over at most 12 audio bindings,
plus the existing O(layers × keyframes) composition and O(words)
typography resolution. All work is on-demand; normal Story preview
and MP4 stay on their existing render path.

**Important limitations:** Export style is merely descriptive metadata:
Stage 9 does not change resolution, codec, frame rate, or IPA. The
creative audio envelope is future-facing for visual intensity/movement,
not already wired to shader uniforms. Demo visual names describe
existing backgrounds and shaders, not novel materials. Frequency
remains normalized high-frequency band energy; a true pitch/frequency
analyzer would be a separate approved stage. Version 1 has no automatic
future schema migrations, cloud sync or remote preset import.
