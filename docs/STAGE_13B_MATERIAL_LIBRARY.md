# Stage 13B — Procedural Visual Material Library

## Base and invariants

Built **on top of** `stage-13-material-engine`, preserving the actual Stage 13
`VisualMaterial → MaterialResolver → MaterialFrame → TurbulentMarbleView`
path. The legacy `liquidMarble` Metal function and its four original
uniforms remain unmodified; all new looks use one additional stitchable
`proceduralMaterial` function in the **same** `Shaders.metal` file and
existing SwiftUI `colorEffect` renderer. No new renderer, MTKView,
AVAudioEngine, feedback textures, temporal simulation or particles.

| Type | Authoring controls, in fixed shared 4-float layout | Accepted audio |
|---|---|---|
| Marble | Original Stage 13 `VisualParameterSet` | beat |
| Liquid Glass | glassAmount / distortion / refraction / surfaceNoise | beat, energy |
| Chrome | metalness / reflection / brightness / contrast | energy, brightness (treble band) |
| Organic Noise | noiseScale / turbulence / flowSpeed / density | bass, movement |
| Atmospheric Smoke | density / turbulence / drift / opacity | energy, movement |
| Advanced Marble | layers / intensity / contrast / veinWidth | beat, bass |

Unknown and legacy reserved type names stay decodable; unsupported
`liquid/glass/noise/fluid` continue to fall back to Original Marble.

### Preset / source contract
The **existing** `CreativeExperiencePreset` catalog exposes Liquid Dream,
Chrome Night, Organic Pulse, Cyber Marble, and Atmospheric Smoke. Former Stage
13 legacy recipes remain unchanged. The existing selection ID and runtime
are reused; no alternative preset framework is created.

The original source timestamp, immutable feature sample, rhythm frame,
composition deterministic seed and material are consumed by the pure resolver.
Both preview and MP4 use the same frozen `CompositionRuntime` and material
frame; GPU animation phase remains the original `StoryRenderFrame.marblePhase`.
Live playback keeps the existing cached feature timeline and render-rate
`MarblePulseDriver`.

### Research (architectural patterns, no code copied)
- [MetalNoise](https://github.com/jmade/MetalNoise): procedural noise and palette mapping
- [SwiftShaders](https://github.com/muhittincamdali/SwiftShaders): typed parameter bridge
- [SwiftUIShaders](https://github.com/krispuckett/SwiftUIShaders): reusable effect composition
- [Inferno](https://github.com/twostraws/Inferno): stitchable SwiftUI shader uniform design
- [MetalCanvas](https://github.com/NakaokaRei/MetalCanvas): renderer abstraction reviewed, rejected here
- [LiquidGlass](https://github.com/BarredEwe/LiquidGlass): refractive look; capture/blur pipeline deliberately NOT ported
- [projectM](https://github.com/projectM-visualizer/projectm): separate preset authoring from render
- [SPH Fluid Metal GPU](https://github.com/Pierre-Joly/SPH-Fluid-Metal-GPU): physics simulation deliberately excluded

### GPU / parity / remaining risks
- Legacy Marble = unchanged 16 value-noise octaves, old pixel path retained.
- New Glass/Chrome/Advanced Marble ~7 value-noise octaves;
  Organic/Smoke ~11 (static counts based on shader branches, not runtime measurements).
- Shared shader args: size, time, 3 palette colors, kind, 4 controls,
  pulse, 4 audio channels, seed. No additional buffer allocations in code.
- Liquid Glass is a translucent **procedural imitation** of refraction and
  surface highlight, NOT actual blurred/refracted framebuffer capture.
- Actual GPU ms/frame, FPS, allocation deltas and golden-image comparison
  require hardware GPU capture / CI screenshot fixtures. Do not claim
  performance or visual parity without measurement.
- Validation gates: `xcodegen generate`, full XCTest, Release, unsigned IPA,
  and manual visual side-by-side on an iOS device.
