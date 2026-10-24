# Stage 72 FINAL — Argon 4 × SwiftUI Expert: depth and material overhaul

## Inputs and evidence

- Argon 4's **GNARLY_Argon_4_Deep_Visual_Research(1).md** (26-reference brief, but the Argon session explicitly confirms only 15 descriptions were available to it; it is **not** an audit of our code).
- 26 user-supplied aesthetic references and previous Stage 71 material improvements, which passed CI.
- Actual `CreativeUniverse.metal`, `TurbulentMarbleView.swift`, `StoryExportMarbleView.swift` and `EnergyBudget`, audited with SwiftUI Expert's performance and view-invalidation guidance.

## Selection of Argon proposals — reality check

| Proposal | Decision | Reason |
|---|---|---|
| Vector Drift as a volumetric tunnel with an angular cage and a central vanishing point | **IMPLEMENTED, cost-bounded approximation** | Builds on the existing 2.5D inverse-radius cylinder. Layered rails, specular highlights and cable coils are calculated at the same source clock; no new render pass |
| Tectonic rock plates, crack metric, tensile fibers | **IMPLEMENTED** | Uses a bounded 3×3 nearest-site + bisector Voronoi approximation, fractures/openings driven by bass and energy; a second braid layer is omitted under low quality |
| Strata with heightfield, terraces, normals and thermal layers | **IMPLEMENTED, stateless** | 3-octave fBm heightfield, terraced silhouette, height-gradient lighting and thermal basin emission derived deterministically from current time/levels |
| Full multi-step SDF raymarching for Vector and 24-step parallax raymarch for Strata | **NOT IMPLEMENTED** | No GPU timing evidence for the user's older iPhone hardware, and the existing live/export pipelines use a shared evaluator; introduce multipass only after measured traces |
| True 20 Hz historical audio texture and accumulated erosion/heat | **DEFERRED** | Current live renderer does not have a seek-indexed audio history bound to both GPU entry points. The Stage 72 'age' parameter is *music-time maturity*, **not** actual past audio history |
| Real time procedural audio engine replacement, second AVAudioEngine, extra SwiftUI timers | **REJECTED** | Existing audio engine and clock must remain intact |
| Potential Jacobian caustics and sampled cover refraction | **DEFERRED** | Would need shared cover texture pipeline in Live & Story and evidence of acceptable performance |
| Original Compiler, Organism, Bubble, Isometric, Prism | **PRESERVED** | Already approved by physical design review; keep identities, IDs and performance behavior |

## Changes in the new version

### Tectonic Mesh (creative look 9)

A *tiled mineral mass* with 18 bounded nearest-point/bisector checks in warped XY coordinates. Distinct cells define mineral plates and coherent fissure widths. The actual crack pixels reveal a shadowed interior with tensile fibers. Bass widens the opening; mid-range modifies strand speed; treble accentuates mineral borders. Under `quality <= 0.68` the extra braided pass is skipped. No mesh engine created.

### Vector Drift 2000 (creative look 10)

A source-time cylindrical tunnel whose longitudinal rails and ribs use actual polar coordinates and inverse-radius perspective to form a distant vanishing point. A near/far falloff, metallic brushed reflectance, and two additional depth-suggesting cables give the impression of a hollow structure. Lower quality skips the cable details. **Important bug fix:** time multiplies *constant* propulsion speed; live bass/mid contribute only bounded offsets, rather than multiplying the entire elapsed time (which used to teleport the whole tunnel late in songs).

### GNARLY Strata (creative look 13)

A heightfield built from bounded fBm, curved folds and sinkhole geometry. Height is quantized into time-evolving terraces with dense mineral contour edges and raking-light gradient shading. Heat tends to occupy basins and responds to the currently available audio while the terrain matures as `sourceTime / duration`. Under `quality <= 0.60` the two extra gradient height samples are omitted. **No false claims of persistent audio history**.

### Common constraints

- Only edits to the **existing** `CreativeUniverse.metal` evaluator and tests; existing `colorEffect` and offscreen Story compute entry points both call identical `universeEval` code.
- `EnergyBudget.secondaryShaderQuality` already controls live quality; Story supplies maximum quality. The effects remain deterministic per source-time + seed + normalized audio levels, but GPU frame pixel parity still needs device comparison.
- No new stateful SwiftUI render subtree, extra `TimelineView`, audio engine, network call, core camera change, Story encoding redesign or migration.
- Preserved Stage 71 material upgrades for Xerox, Caustic, Subcultural, Liquid and Nocturnal.
- Preserved approved Subatomic Bubble, Isometric Chasm, Compiler, Organism and existing UI visual taxonomy.
- Visible badge `v72`, `CFBundleVersion = 72`, XcodeGen marketing `1.0.72`.
- New shader regression checks assert Voronoi/heightfield/musical speed boundaries and the two GPU entry points.

## Release gates before promotion

1. GitHub Actions full iOS tests and **Build Unsigned IPA (Free Route)** must both pass; verify the actual unsigned IPA artifact ID, run ID and expiry.
2. On physical iPhone test Vector / Tectonic / Strata on 2+ contrasting themes at Off/Fluid/Reactive.
3. Pause and seek at 01:00 and 03:00: no sudden jump beyond bounded audio displacement; no shader teardown or black frames.
4. Watch temperature/battery/fps and report slow mode on iPhone 11-class hardware. A passed macOS CI compile is **not** a guarantee of a 60fps device budget.
5. Inspect Story export at the same source time as the player and make sure geometry remains legible, no wrong orientation, and typography stays on top.
6. Repeat GNARLY karaoke recording preview and audio download tests from Stage 70 to ensure no unrelated regressions.
7. Avoid updating the beta invitation's IPA until a real device test is approved.

## Next engineering milestone (only if measured)

Bind deterministic, compact `AudioFeatureTimeline` history with the same seed and source clock to **both** GPU entry points for Strata fossilization. Only after memory, parity and thermal evidence should a multi-pass SDF/raymarch implementation be considered.
