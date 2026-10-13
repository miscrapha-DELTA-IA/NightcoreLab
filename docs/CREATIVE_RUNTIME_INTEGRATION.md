# Creative Runtime Integration (Stages 10A–13B)

Closes the integration of the Stage 10A–12 work on one branch, with CI as the
validator. No new layers, shaders or engines.

## What was found
| Branch / PR | State | Decision |
|---|---|---|
| `stage-10b-typography-parity` (#31) | Merged into `main` | **Broke the test target**: `TypographyExportParityTests` imported SwiftUI, whose `BackgroundStyle` collides with the app's (`'BackgroundStyle' is ambiguous`). Hotfix PR #33. |
| `stage-10a-runtime-wiring` (#30, other agent) | Open, written before 10B/10C | Duplicates 10B (typography in Story, with a second word renderer and the removed `KaraokeTypographyStyle`) and 10C (compiled runtime). **Ported its unique parts** (below); the PR should be closed as superseded. |
| `stage-10c-runtime-stabilization` (#32) | Open | Included here. |
| `stage-11-rhythm-intelligence-v2`, `stage-12-visual-material-marble` | Pushed, never compiled | Included; first full simulator run found only the test ambiguity above. |

## Ported from Stage 10A
- **Always one runtime**: `StoryRequestBuilder` freezes a composition even with
  audio reaction off (selected recipe, reaction `.off` → neutral Marble, same
  pixels). New `creativePresetID` parameter (default "original").
- **Layer pixels**: `ResolvedLayerFrame.storyModifiers(kind:frame:)` →
  `StoryLayerModifiers` (pure), applied by `StorySceneView` to background,
  overlay scrim, artwork tile (player) and lyrics card. Identity is a true
  bypass (default layers keep the exact legacy hierarchy); a layer outside its
  clip hides its element; `intensity` is reserved. Not reordered by zIndex.
- **Full test suite on PRs**: `ios.yml` also runs on `pull_request` to `main`.

## Other integration fixes
- `ios.yml`: on failure, xcodebuild `error:` / failed-test lines are published
  as annotations (job logs are not always reachable; annotations are, through
  the REST API).
- `CreativeExperiencePreset.visualMaterial`: the chain
  experience → program → `VisualMaterial` → `MarbleUniforms` → Metal uniforms.
  There is no separate `VisualParameterSet` type: `MarbleUniforms` is that set
  for the Marble, and `CreativeParameterFrame` remains the program-level set.
- `RhythmFrame.at`: first-downbeat lookup limited to the first bar (it ran a
  linear scan over all beats on every live render frame).
- `RhythmAnalyzer`: explicit `UnsafeBufferPointer<Float>` construction.

## Guarantees and where they are tested
| Guarantee | Test |
|---|---|
| Preview = export: composition frame, typography frame, distortion, pulse and layer modifiers, all 5 styles, reaction on/off | `CreativeIntegrationTests.testPreviewAndExportResolveIdenticalValues` |
| App typography = Story typography | `TypographyExportParityTests` |
| Compiled runtime = legacy resolver (bit-exact) | `RuntimeStabilizationTests` |
| Layer values reach exported pixels; default layers are a bypass | `CreativeIntegrationTests` |
| Rhythm accuracy / determinism / RhythmFrame | `RhythmAnalyzerTests` |
| Material determinism, pulse only with reliable rhythm | `VisualMaterialTests`, `CreativeIntegrationTests` |
| Preset compatibility (built-in, experiences, legacy JSON) | `CreativeIntegrationTests`, `TypographyExportParityTests`, `RhythmAnalyzerTests` |

## Validation actually run
GitHub Actions "Build Unsigned IPA (Free Route)" via `workflow_dispatch`
(macOS runner, Xcode latest-stable): `xcodegen generate`, full `xcodebuild
test` on an iPhone simulator, Release build and IPA packaging. See the PR for
the run links and results. Not run: Instruments on a physical iPhone (no
device here); the signposts and performance tests are in place for that.

## Stage 12.5 — Creative Experiences in the product

### How an experience is created
An experience is data, not a new system. `CreativePresetCatalog.experiencePresets`
builds each one from an existing recipe:

```
recipe (CreativeVisualProgram: rules + shader vocabulary)
  → CreativePreset renamed (id "cyber-night", typography style from the preset)
  → VisualComposition (CreativeSnapshotAdapter.wrap, default layers, deterministic seed)
  → CreativePresetPackage (composition + TypographyPreset)
  → CreativeExperiencePreset (+ CreativeAudioMapping, description)
```

| Experience | Program (visual) | Typography | Audio mapping (rendered part) |
|---|---|---|---|
| Cyber Night | Night Drive | Glitch, intensity 0.7, seed 0xC1B3 | beat → typography +0.2 |
| Liquid Dream | Soft Flow | Magazine Cutout, intensity 0.3, seed 0xD123 | (none on typography) |
| Neon Pulse | Bass Pulse | Kinetic, responsive, intensity 0.55, seed 0xB455 | beat → typography +0.35 |

To add one: append an `authoredExperience(...)` entry. It appears in the
picker automatically (`selectableExperiences`).

### How it reaches the preview (player + karaoke)
- **One selection key**: the existing `creativePresetID` preference holds a
  recipe id *or* an experience id. The "Preset" menu (ContentView, "RITMO
  VISUAL") lists *Receitas* and *Experiências*.
- **Visual**: `effectiveProgram(id:…)` resolves ids through
  `recipe(for:)` → the experience's program (rules, shader parameters,
  intensity, motion). `CreativeReactiveAccent` (live Marble, 12 Hz) and the
  `MarblePulseDriver` (beat pulse) use it unchanged. `program(for:)` is not
  changed: unknown ids still fall back to Original.
- **Typography**: selecting an experience sets the karaoke style preference
  to the experience's style (`typographyStyle(afterSelecting:current:)`).
  `typographyPreset(selection:style:font:reacts:)` then returns the
  experience's intensity, seed and mapping with the user's font; its audio
  reaction only while visuals react. Choosing another style afterwards falls
  back to the plain `TypographyPreset.current` (pre-12.5 behavior).
- **Audio mapping**: `typographyAudioMapping(selection:style:reacts:)` →
  `TypographyLayer.experienceMapping` → `TypographyPreset.modulated(by:features:)`
  (one function, also used by `CreativeExperienceResolver`).
- **Live features**: `CreativeReactiveAccent` hands its frozen feature
  timeline to `CreativeLiveUniforms` (`onFeatureTimeline`);
  `NowPlayingScreen` puts the uniforms in the environment; the active
  karaoke line samples it with `CompositionAudioSampler` at the clock's
  source time — the same sampler the Story uses — and resolves through
  `TypographyLayer.resolve`, the Story's entry point.
- Not changed by a selection: AppTheme and font (explicit product rule).

### How it reaches the export
`NowPlayingScreen.shareVideo` → `StoryRequestBuilder.make(..., creativePresetID:)`
freezes, once:
- the composition from the effective program, with the experience's
  composition seed;
- `typographyPreset` and `typographyAudioMapping` from the same catalog
  helpers as the karaoke (reaction ⇔ `reactiveProgram != nil`);
- prepared lyric seeds.

`StoryVideoRequest.typographyLayer(atLyricTime:)` is the single builder used
by `StoryDraftPreview` (scrub preview) and `StorySceneView` (every MP4
frame), so preview and export cannot diverge.

### Marble tuning (material, not shader logic)
`VisualMaterial` now carries `beatPulseIntensity` (stored as `beatPulse`),
`pulseDecay`, `downbeatBoost` (= 1 − `offbeatScale`), `warpAmount` and
`brightnessBoost`. The last two were constants in `liquidMarble`; they are
now two uniforms with the same defaults (0.18, 0.10). The shader algorithm
is unchanged and every pulse term is still an exact zero when the pulse is
0. No preset changes these values yet (visual tuning needs a device).

### Guarantees and tests (12.5)
| Guarantee | Test |
|---|---|
| Experiences use the existing selection; recipes/unknown ids unchanged | `CreativeExperienceUXTests.testExperiencesShareTheExistingPresetSelection` |
| Selection loads visual, typography, mapping, material | `…testSelectingAnExperienceLoadsVisualTypographyMappingAndComposition` |
| Recipes and overridden styles keep pre-12.5 typography | `…testRecipesAndOverriddenStylesKeepThePreviousTypography` |
| Story freezes the experience (program, seed, typography, mapping, material) | `…testStoryFreezesTheSelectedExperience` |
| Preview = export with an audio envelope | `…testExperiencePreviewAndExportResolveIdenticalFrames` |
| Mapping reaches exported typography | `…testExperienceMappingReachesStoryTypography` |
| Live karaoke = Story for the same source time | `…testLiveKaraokeTypographyMatchesTheStory` |
| Material tuning defaults = Stage 12 look; bounded; Codable-compatible | `VisualMaterialTests` (12.5 section) |
| Rhythm on genre fixtures | `RhythmGenreFixtureTests`, see `RHYTHM_REAL_WORLD_VALIDATION_STAGE12_5.md` |

## Material and reaction pipeline (Stages 13/13B, consolidated)

Three single sources of truth; every consumer goes through them.

| Concern | Single source | Consumers |
|---|---|---|
| **Which material** (Experience → Material) | `CreativeExperienceResolver.material(experience:recipe:)` — the experience's authored material, else the reaction-free Marble of its program | `StoryRequestBuilder`, `CreativeReactiveAccent` (live driver), `CompositionRuntime` (default), `CreativeExperiencePreset.visualMaterial`, `CreativePresetCatalog.material(selection:)` (used by `NowPlayingScreen`, which never decides) |
| **How much it reacts** (Off / Subtle / Reactive) | `CreativeReactionProfile.gain` (0 / 0.35 / 1), applied once by `MaterialResolver` | `CompositionRuntime`, `MarblePulseDriver` (via `CreativeReactiveAccent`), `AudioVisualMapper`, `CreativeParameterResolver`, `LayerAudioBinding` |
| **Which layer maps audio onto the material** | `CreativeReactionProfile.materialRoute` — `.program` (recipes: program equations drive distortion) or `.material` (experiences: the authored `MaterialAudioMapping` drives distortion, brightness, accent and movement). Never both. | `MaterialResolver` |
| **Contract between composition and shader** | `MaterialFrame` (`parameters: VisualParameterSet`, type, controls, signals, seed, timestamp). `MarbleUniforms` is a typealias of `VisualParameterSet`. | `CompositionRuntime` → `ResolvedCompositionFrame.materialFrame` → `StorySceneView` / `TurbulentMarbleView` (`resolvedFrame` → shader) |

```
selection ─► CreativeExperienceResolver.material ─► CompositionRuntime (frozen)
                                                        │ gain  = CreativeReactionProfile.gain
                                                        │ route = CreativeReactionProfile.materialRoute
                                                        ▼
              timestamp + AudioFeatures + RhythmFrame ─► MaterialResolver ─► MaterialFrame ─► shader
```

- **Story**: `StoryVideoRequest.resolvedFrame(_:audioTimeline:rhythm:)` is the
  one call used by the scrub preview and the exporter (same timestamp,
  AudioFeatures and RhythmFrame). Requests without a frozen runtime get one
  from `renderRuntime`; there is no second resolution branch.
- **Live player**: `MarblePulseDriver.frame(parameters:)` calls the same
  resolver with the same gain and material for the clock's source time;
  `TurbulentMarbleView.resolvedFrame` produces one `MaterialFrame` per render
  frame for both shader paths (Marble and procedural).
- Tests: `VisualMaterialEngineTests` (route never summed, live = Story,
  Stage 12.5 parity through the profile), `CreativeIntegrationTests`
  (preview = export with shared inputs, experience → material),
  `MaterialLibraryTests` (movement only from the material mapping).
- Open product decision (not architecture): Cyber Night uses `cyber-chrome`
  (chrome-tuned Marble) rather than the procedural `.chrome` material.

## Known gaps (UX review, updated in 12.5)
1. ~~Creative Experience presets are not selectable.~~ Done in 12.5.
2. Experience `visualIntensity` / `movement` audio targets are still only
   resolved by `CreativeExperienceResolver`: no renderer consumes them yet
   (would change the Marble look; left for the Material Engine stage).
3. Live typography reacts once the reacting run has loaded its feature
   timeline (shortly after play/selection); until then it shows the
   non-reacting frame. Low Power / Reduce Motion disable reaction in both the
   player and the captured Story, as for the Marble.
4. No UI signal when rhythm is insufficient (the pulse silently stays off).
5. The first Story preview of a track waits for the rhythm decode.
6. Glitch draws jitter/flicker only (no RGB split), identically in app and MP4.
7. Story layout (canvas, 35 pt type, glow 7) intentionally differs from the
   karaoke screen; values are identical, layout is not.
