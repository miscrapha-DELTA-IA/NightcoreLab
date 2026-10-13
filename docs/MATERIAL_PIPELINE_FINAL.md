# NightcoreLab Material Pipeline Final (audit, 2026-10-12)

Scope: `main` after #39 (Stage 13) and #40 (Stage 13B), plus the final
consolidation commit. Method: code search over `NightcoreLab/Sources` for
material construction/selection, reaction literals, audio→visual routes and
Marble parameter types; the claims below are also covered by tests.

## 1. No View decides the material — PASS

| Site | What it does |
|---|---|
| `NowPlayingScreen` (3 call sites) | passes `CreativePresetCatalog.material(selection:)` — a lookup into the single rule, no fallback logic (the former `selectedMaterial` was removed) |
| `BackgroundLayer`, `PlayerBackgroundView`, `TurbulentMarbleView` | receive a material/frame as input; default `.legacyMarble` only when a caller passes nothing |
| `StorySceneView` | takes the frozen runtime's material; `.legacyMarble` only when no runtime can exist (invalid timeline) |
| `StoryRequestBuilder` (model, not a View) | `CreativeExperienceResolver.material(...)` |

The only places that construct or choose materials are
`CreativeExperienceResolver.material`, `VisualMaterial.marble(for:)` (the
rule's recipe branch) and the authored data in `VisualMaterialCatalog` /
`CreativePresetCatalog.experiencePresets`.

## 2. No layer duplicates audio mapping — PASS (one residual noted)

- Reaction gain: one definition, `CreativeReactionProfile.gain`. Remaining
  `0.35` literals in `Creative/` are unrelated (a smoke control default, a
  chrome pulse amount, an AudioVisualMapper band weight) plus
  `TypographyAudioReaction.gain` — a separate typography enum by design.
- Material audio: exactly one route per frame (`materialRoute`). Program
  equations reach the material only for recipes; authored mappings only for
  experiences. Movement for organic/smoke comes from the material mapping,
  not from the program's `lyricKinetics`.
- Residual (not in any render path): `AudioVisualFrameBus` (Fosfora seam,
  used only by `FosforaAudioVisualBridgeTests`) keeps its own target mapping.
  Recommendation: remove or route through `MaterialResolver` when a live
  analyzer is introduced.
- Known, intentional second layer: `CreativeAudioMapping` (experience)
  drives typography intensity only; its `visualIntensity` / `movement`
  targets are still not rendered (documented gap, not a duplicate route).

## 3. No duplicated Marble parameter — PASS

- `VisualParameterSet` is the single contract: authored on
  `VisualMaterial.parameters`, resolved in `MaterialFrame.parameters`, bound
  to the shader as `MarbleUniforms` (typealias). `VisualMaterial`'s
  `beatPulse`/`warpAmount`/… are read-only views of `parameters`.
- `TurbulentMarbleView` builds one `MaterialFrame` per frame (`resolvedFrame`);
  the parallel `resolvedUniforms`/`resolvedMaterial` pair was merged (the live
  driver was evaluated twice per frame).
- `StorySceneView` hands the shader only the `MaterialFrame`.

## Validation

CI on `main` after each merge (full XCTest on the simulator, Release build,
unsigned IPA, `macos-latest`) and the iOS Build workflow on the `macos-15`
runner (Xcode `latest-stable`; the exact Xcode build is in the job log, which
this environment cannot read). See the PR
of the consolidation commit for run links.

## Open items (product, not architecture)

1. Cyber Night: `cyber-chrome` (Marble) vs procedural `chrome` — design decision.
2. Experience materials now react only through their mapping: visual review
   on a device recommended (less distortion than the summed Stage 13 values).
