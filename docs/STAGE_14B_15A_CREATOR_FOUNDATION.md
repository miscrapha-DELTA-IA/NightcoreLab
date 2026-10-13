# NightcoreLab — Stage 14B + 15A (single milestone)

## Audited legacy boundaries

| Existing component | Source of truth | New adaptation |
| --- | --- | --- |
| StoryVideoRequest.size | 540×960 original logical canvas | 9:16 bypass preserved |
| StorySceneView | Vertical header, cards and lyrics | Optional layout policy for 1:1 and 16:9 |
| StoryRenderTimeline | Timestamp/frame-grid | Unmodified |
| ExportProfile | Aspect, quality, crop | Existing 14A export contract reused |
| TypographyResolver | Word fill, seed, Magazine appearance | Existing frame mapping, not a new resolver |
| MaterialResolver | Procedural materials, parameters and signals | Existing MaterialFrame mapping, not a new shader |
| CompositionRuntime | Frozen and compiled composition | Reused per session |
| StoryFrameRenderer | SwiftUI to CGImage for preview/export | Resolution follows selected logical viewport |
| StoryVideoExporter / SharePackage | H.264, audio mux and files | Same paths; layout frozen before frame loop |

Current viewport enters the shader through TurbulentMarbleView and GeometryReader.size. 14A centered/scaled the portrait scene for nonportrait formats. Stage 14B puts authored Story elements in explicit safe regions without changing the shader or creating a renderer.

## Final architecture

CreativeExperiencePreset + ExportProfile + CreatorControls
→ CreatorPreset (Codable, schema v1)
→ ControlMapping → CreatorParameterSet
→ Session-frozen StoryVideoRequest (CompositionRuntime, CompositionLayoutPolicy, parameters)
→ existing StoryRenderTimeline
→ existing CompositionRuntime producing MaterialFrame and TypographyFrame
→ ControlMapping applies typed parameters to frames
→ existing StorySceneView / StoryExportCanvas
→ existing StoryFrameRenderer (same pixels for preview and MP4)
→ existing StoryVideoExporter → SharePackage

No new clock, Metal engine, FFT pipeline or renderer. Creator edits freeze a session; scrub preview samples existing frames. Experience/material selection can rebuild the runtime once when selection changes; a control-only edit reuses the current runtime.

## Safe composition regions

| Ratio | Logical scene | Material viewport | Behavior |
| --- | --- | --- | --- |
| 9:16 | 540×960 | Original | Legacy scene and pixel compatibility |
| 1:1 | 540×540 | 540×540 | Safe-centered player, lyric area and footer |
| 16:9 | 960×540 | 960×540 | Wide layout with dedicated title/lyric/visual regions |

Safe-area-preserving builds native adaptive geometry for 1:1 and 16:9. Explicit aspectFit preserves the complete old portrait scene inside black bars. Explicit centerCrop is allowed for player only; lyrics always resolve to safeAreaPreserving. Quality changes encoder pixel dimensions, FPS and bit rate but not logical geometry.

Neon fill and Magazine word IDs, seeds, palette indices and rotation remain TypographyResolver outputs. Adaptive typography changes width and font size while retaining KaraokeWordView. MaterialViewport records logical size and aspect ratio; the existing shader continues receiving its native GeometryReader size.

## Creator controls

All nine controls are normalized to [0, 1] and default to 0.5 (identity).
- materialIntensity: existing MaterialFrame intensity, parameter and signal gains.
- distortion, brightness, movement: existing VisualParameterSet distortion, brightness and warp / movement signal.
- typographyScale, glow, kineticAmount: existing TypographyFrame words, animation and KaraokeWordView glow radius.
- beatSensitivity, energyResponse: existing MaterialFrame beat pulse and energy/brightness response.

The mapping clamps output through the existing bounded parameter vocabulary; no view calls a shader or manipulates audio. Nonfinite and invalid normalized values are rejected at decoding.

CreatorPreset contains experienceID, materialID, TypographyPreset, CreatorControls, ExportProfile and schema version. CreatorPresetStore serializes JSON in UserDefaults locally. No backend, cloud or extra package. A future share format can serialize this preset independently of ShareMetadata v1.

## Reference research — architectural study, no code copied

| Repository | Licence metadata | Role |
| --- | --- | --- |
| projectM-visualizer/projectm | LGPL-2.1 | Presets separated from renderers |
| astrofox-io/astrofox | MIT | Music/visual workflow |
| better-lyrics/composer | AGPL-3.0 | Word timeline composition |
| muhittincamdali/SwiftShaders | MIT | Shader parameter isolation |
| krispuckett/SwiftUIShaders | MIT | SwiftUI/Metal integration |
| mixedinkey-opensource/MIKMIDI | NOASSERTION | Future MIDI architecture only |
| orchetect/swift-midi | MIT | Future MIDI vocabulary only |
| AudioKit/DrumPadPlayground | MIT | Musical controls |
| juraskrlec/JSWaveform | MIT | iOS 17+ waveform example |
| Matt54/SwiftUI-AudioKit-Visualizer | MIT | Audio/visual separation |
| tnantoka/Edhita | MIT | Editor state model |

Maintenance: projectM, Astrofox, BetterLyrics, SwiftUIShaders and swift-midi recorded activity in September–October 2026; other projects vary. No third-party code imported, so none imposes deployment changes. NightcoreLab continues targeting iOS 17+.

## Tests and release gates

Directed tests: AdaptiveCompositionLayoutTests and CreatorControlTests cover 9:16 parity, 1:1, 16:9, safe typography, viewport/material parity, Magazine seed determinism, all nine control destinations, local JSON round trip, timestamp repeatability and preview/export pixel identity. Run existing ShareExportPipelineTests, MaterialLibraryTests and TypographyEngineTests for regressions.

Full gate only before final merge: xcodegen generate, full XCTest, unsigned Release build, IPA artifact, verified on final HEAD. Record real-device time and allocations before claiming performance gains.

Not implemented: MIDI transport, AUv3, plugins, stems, heavy AI, cloud, marketplace, new shader/renderer, new timeline, new codec or backend.
