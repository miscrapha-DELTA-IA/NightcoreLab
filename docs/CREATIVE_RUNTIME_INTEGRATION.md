# Creative Runtime Integration (Stages 10A–12)

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

## Known gaps (UX review)
1. **Creative Experience presets are not selectable.** The UI offers theme,
   reaction, 4 programs, effect and font separately; Cyber Night / Liquid
   Dream / Neon Pulse exist only as data. "Choose preset → see → export" is
   true per setting, not per experience.
2. No UI signal when rhythm is insufficient (the pulse silently stays off).
3. The first Story preview of a track waits for the Rhythm v2 decode.
4. Glitch draws jitter/flicker only (no RGB split), identically in app and MP4.
5. Story layout (canvas, 35 pt type, glow 7) intentionally differs from the
   karaoke screen; values are identical, layout is not.
