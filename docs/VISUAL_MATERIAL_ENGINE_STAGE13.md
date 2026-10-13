# Stage 13 — Advanced Visual Material Engine Foundation

## Base and scope

Based on PR #38, commit `89056d1` (Stage 12.5 plus audio identity fix).
At inspection, main was `3370c22` and PR #38 remained open. This change must
retain #38; it does not assert that its cancelled test/IPA runs passed.
No renderer, shader algorithm, export format, FFT, cache, material editor,
SPH, particles, refraction, LiquidGlass or Share Engine added.

## Initial audit

- `TurbulentMarbleView` binds `ShaderLibrary.liquidMarble` via `colorEffect`.
- Explicit uniforms: size, time, deep/body/accent colors, reactiveDistortion,
  beatPulse, pulseWarp and pulseGlow. Position/currentColor are supplied by SwiftUI.
- Existing material parameters: beat amount, decay, offbeat scale, warp gain,
  brightness gain. Distortion was delivered separately through program parameters.
- `VisualParameterSet` did not exist. `VisualPreset.ShaderParameters` is a
  different, legacy authoring vocabulary; it is preserved without reinterpretation.
- `CreativeMarbleFrameResolver` evaluates the existing creative program, including
  its fixed 150 ms onset look-back. It remains the source-compatible program adapter.
- Shader fBM constants, octaves, palette, size and animation phase are unchanged.

## Architecture

`CreativeExperiencePreset.material?` → `VisualMaterial` → `MaterialResolver`
→ `MaterialFrame` → `ResolvedCompositionFrame.materialFrame`
→ existing StorySceneView/TurbulentMarbleView → existing Metal shader.

The runtime is compiled once. It samples the source audio timestamp and rhythm,
then attaches one resolved material value. Typography copying preserves that value.
StoryRequestBuilder freezes the selected experience's material; StoryDraftPreview
supplies the same rhythm analysis to the same runtime that StorySceneView uses for
export. Legacy direct requests get a compatibility frame using the same resolver.

The live playback adapter reads the source clock once per rendered frame. Existing
program distortion remains polled at <=12 Hz; material audio mapping and pulse use
the render cadence (normally <=60 Hz). No additional display link or audio graph.
Playback/scene/low-power/reduce-motion gates remain in the existing UI adapter.

## Parameters, bounds and mapping

| Field | Bounds | Default |
| --- | --- | --- |
| distortion | 0...1 | 0 |
| beatPulse | 0...1 | 0 |
| pulseDecay | 1...20 | 6 |
| offbeatScale | 0...1 | 0.7 |
| warpAmount | 0...0.5 | 0.18 |
| brightnessBoost | 0...0.3 | 0.10 |
| intensity | 0...1 | 1 |

`MaterialAudioMapping` explicitly stores bass→distortion, energy→brightness,
beat→pulse, downbeat→accent gains plus confidence floor/range and downbeat threshold.
All input constructors and JSON decoding clamp bounds and replace nonfinite values.
Energy/accent adjust the **existing pulse-glow coefficient**: no independent
brightness effect is claimed when there is no pulse. Downbeat accent needs reliable
bar position. Missing rhythm never invents beats from onset flags.
Reaction off suppresses mapping; subtle scales authored mappings once. Legacy
program-derived materials already include their original pulse scaling.

Only `marble` is supported. Reserved type tags liquid/glass/chrome/noise/fluid are
serializable vocabulary, explicitly falling back to Original Marble on resolution.
Four material recipes only in Stage 13: Original Marble, Cyber Chrome, Liquid Dream, Neon Pulse (13B replaces Liquid Dream's material with Liquid Glass and removes the unused recipe).
Existing Cyber Night/Liquid Dream/Neon Pulse experiences reference the latter three;
the saved experience IDs and original recipe selection remain intact. Chrome and
Liquid are visual recipe names, not new shader implementations.

## Determinism and compatibility

Resolver inputs are immutable material, audio sample, rhythm sample, timestamp,
existing program parameters and explicit reaction gain. No random, global mutable
state, time reads or render history. Invalid times resolve at zero with no audio
contribution. A frame's timestamp is source time; the existing frozen Story animation
phase remains separate to preserve previous pixels.

Old Stage 12/12.5 flat material JSON decodes with identical defaults. New encoding
uses the canonical typed parameter set. Experience schema 1 accepts an optional
material; missing material still derives from the old program. Existing creative
programs, packages, typography and composition serialization remain unchanged.

## Research (read-only; no source copied)

| Repository / inspected source | Revision | Decision |
| --- | --- | --- |
| [jmade/MetalNoise](https://github.com/jmade/MetalNoise/blob/990a098cc943beb1d18b8b848ef8f48ddc735115/Shaders.metal) | `990a098cc943` | Noise uniforms, turbulence and frequency parameters. Keep current fBM/domain warp; no copied code. |
| [muhittincamdali/SwiftShaders](https://github.com/muhittincamdali/SwiftShaders/blob/034cfa5e73f52a3f30c312e0a605e14c0c6fa3c0/Sources/SwiftShaders/Bridge/MetalToSwiftUIBridge.swift) | `034cfa5e73f5` | Parameter-facing modifiers; inspected bridge is a mock opacity modifier, not a usable Metal implementation. |
| [krispuckett/SwiftUIShaders](https://github.com/krispuckett/SwiftUIShaders/blob/6b644a8bd4f3131401bd6765990e476352d3cdef/Sources/SwiftUIShaders/ShaderEffects.swift) | `6b644a8bd4f3` | Typed wrappers mirror shader signatures. Reject wall-clock driven animation inside the material resolver. |
| [twostraws/Inferno](https://github.com/twostraws/Inferno/blob/a40c7a0bdec03aae1bd0b96c41d6a75451bafd2c/Sources/Inferno/InfernoShaderLibrary.swift) | `a40c7a0bdec0` | Central shader lookup and effect organization. Retain existing ShaderLibrary; no dependency. |
| [NakaokaRei/MetalCanvas](https://github.com/NakaokaRei/MetalCanvas/blob/8c1ee3b51947f4e14d4c4338915a970a99b23ab8/Sources/MetalCanvas/MetalCanvas.swift) | `8c1ee3b51947` | Canvas/uniform responsibility split. Do not adopt another pipeline or its timer. |
| [projectM-visualizer/projectm](https://github.com/projectM-visualizer/projectm/blob/349b7cc2db312d47cef6be24c6856ced6643a385/src/libprojectM/MilkdropPreset/PresetState.hpp) | `349b7cc2db31` | Preset parameters and audio features separated from drawing. Do not adopt mutable per-frame preset state. |
| [BarredEwe/LiquidGlass](https://github.com/BarredEwe/LiquidGlass/blob/81d921841b517c189dd63d6f9f455ef5f4318062/Sources/LiquidGlass/SwiftUI/MetalShaderView.swift) | `81d921841b51` | Future refraction research only. Snapshot textures, MTKView and wall clock are outside this stage. |
| [Pierre-Joly/SPH-Fluid-Metal-GPU](https://github.com/Pierre-Joly/SPH-Fluid-Metal-GPU/blob/e9ee3fbef8e1b1e5596bcc79ed006f2c8a28cc7c/SPH/Control/Renderer.swift) | `e9ee3fbef8e1` | Research only: stateful integration, density/force passes, particle buffers and substeps deferred. |

## Validation and performance

`VisualMaterialEngineTests` covers independent pre-13 uniform equivalence across
recipes/reaction modes/phases, deterministic seeks, route bounds, absent/weak rhythm,
invalid timestamps, preview/export frames at different playback speeds and FPS,
legacy and new Codable payloads, reserved types, and the four recipe catalog.
Pixel test compares the old explicit-uniform view path against MaterialFrame at
fixed theme/size/phase. It rejects blank captures and attaches before/after PNGs.

The XCTest cost test resolves 10,000 frames with clock and memory metrics, consumes
a checksum to prevent dead-code elimination and prints value-layout sizes.
No per-frame arrays/dictionaries, sorting, IO, allocation requests or cache in
MaterialResolver; existing strings are retained as values. Memory metric measures
footprint, **not a count of transient heap allocations**; an Instruments Allocations
profile on hardware remains needed for that count and for device GPU budgets.
Preview resolves once per scrub event; export once per encoded frame (existing
profiles); live maps once per displayed frame. Resolver complexity is O(1).

Local executor is Linux without Swift/Xcode/XcodeGen; no local Apple test, GPU
comparison, Release or IPA success is claimed. The existing iOS CI workflow runs
xcodegen, the complete XCTest suite, Release build and unsigned IPA packaging.
Results must be recorded after CI. Physical-device visual review and allocation
profiling remain limitations even when simulator checks pass.

## Risks

- PR #38 is a dependency until merged; this branch preserves its commits.
- Artistic Chrome/Liquid recipes remain constrained to Marble's existing uniforms.
- Live legacy distortion uses its established 12 Hz sampling; exact frame parity is
  asserted for frozen Story preview/export, not arbitrary wall-clock live captures.
- New-schema materials are readable by this version; older apps may ignore the
  additive experience material field (no forward compatibility claim).
- Simulator pixel comparison is not a physical-device rendering/performance review.

## Changed files

- `NightcoreLab/Sources/Creative/CreativeExperiencePreset.swift`
- `NightcoreLab/Sources/Creative/CreativeExperienceResolver.swift`
- `NightcoreLab/Sources/Creative/CreativePresetCatalog.swift`
- `NightcoreLab/Sources/Creative/CreativeReactiveAccent.swift`
- `NightcoreLab/Sources/Creative/VisualComposition/CompositionFrameResolver.swift`
- `NightcoreLab/Sources/Creative/VisualComposition/CompositionRuntime.swift`
- `NightcoreLab/Sources/Creative/VisualComposition/ResolvedCompositionFrame.swift`
- `NightcoreLab/Sources/Creative/VisualComposition/ResolvedFrameRendererAdapter.swift`
- `NightcoreLab/Sources/Creative/VisualMaterial/MarblePulseDriver.swift`
- `NightcoreLab/Sources/Creative/VisualMaterial/MaterialAudioMapping.swift`
- `NightcoreLab/Sources/Creative/VisualMaterial/MaterialFrame.swift`
- `NightcoreLab/Sources/Creative/VisualMaterial/MaterialResolver.swift`
- `NightcoreLab/Sources/Creative/VisualMaterial/VisualMaterial.swift`
- `NightcoreLab/Sources/Creative/VisualMaterial/VisualMaterialCatalog.swift`
- `NightcoreLab/Sources/Creative/VisualMaterial/VisualParameterSet.swift`
- `NightcoreLab/Sources/Share/StoryDraftPreview.swift`
- `NightcoreLab/Sources/Share/StoryModels.swift`
- `NightcoreLab/Sources/Share/StorySceneView.swift`
- `NightcoreLab/Sources/TurbulentMarbleView.swift`
- `NightcoreLabTests/CreativeExperienceUXTests.swift`
- `NightcoreLabTests/RuntimeStabilizationTests.swift`
- `NightcoreLabTests/VisualMaterialEngineTests.swift`
- `docs/VISUAL_MATERIAL_ENGINE_STAGE13.md`

## Consolidated material pipeline (pre-merge alignment)

```
selection id (creativePresetID)
  └─ CreativeExperienceResolver.material(experience:recipe:)   ← THE material rule
        experience.material ?? VisualMaterial.marble(for: program)   (reaction-free)
  └─ CompositionRuntime(composition:material:)   (frozen once per Story / per live run)
        frame(at:features:rhythm:)
          gain  = CreativeReactionProfile.gain(program.audioReaction)   ← THE reaction rule
          route = CreativeReactionProfile.materialRoute(for: material)  ← ONE audio route
          MaterialResolver.resolve(material, features, rhythm, timestamp, programParameters, gain)
            → MaterialFrame.parameters : VisualParameterSet  (= MarbleUniforms) → shader
```

- **Material rule**: `CreativeExperienceResolver.material(experience:recipe:)`.
  Used by `StoryRequestBuilder` (Story), `CreativeReactiveAccent` (live pulse
  driver), `CompositionRuntime` (default), `CreativeExperiencePreset.visualMaterial`
  and `CreativePresetCatalog.material(selection:)`. Views never choose.
- **Reaction rule**: `CreativeReactionProfile.gain` (Off 0 / Subtle 0.35 /
  Reactive 1). Materials no longer bake it in; it is applied once by the
  resolver. Also consumed by `AudioVisualMapper`, `CreativeParameterResolver`
  and `LayerAudioBinding` (same literals, now one definition).
  `TypographyAudioReaction.gain` is a separate (typography) enum, unchanged.
- **One audio route per frame**: recipes (legacy mapping) → program equations
  drive the distortion; experiences with an authored `MaterialAudioMapping` →
  the mapping drives distortion/brightness/accent and program distortion is
  ignored. Before this, Neon Pulse added Bass Pulse's bass rule (0.7) AND the
  material's bassToDistortion (0.20).
- **One parameter contract**: `VisualParameterSet` (authored on the material,
  resolved in `MaterialFrame`); `MarbleUniforms` is a typealias of it.
- **One Story path**: `StoryVideoRequest.resolvedFrame(_:audioTimeline:rhythm:)`
  is called by the scrub preview and by the exporter; requests without a
  frozen runtime get one from `renderRuntime` (no legacy branch).
- `CreativeExperienceResolver.resolve(..., runtime:)` reuses the frozen runtime
  (`CompositionRuntime.experienceFrame` passes itself) instead of recompiling.

Visible consequence: experience materials react only through their mapping
(less distortion than before on Cyber Night / Neon Pulse, where the program's
distortion was being added on top). Recipes are unchanged (distortion
bit-exact; pulse equal within 1e-12 because the 0.35 gain is now applied
after, not before, the pulse product).
