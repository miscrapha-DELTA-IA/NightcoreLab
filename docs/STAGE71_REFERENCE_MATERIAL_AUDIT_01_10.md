# GNARLY · Stage 71 EXP — High-Fidelity Material Geometry
## Reference intake 01–10 of 27 submitted, 2026-10-24

**Status:** First technical/visual pass only, not an approved visual identity. Do not replace the user's current IPA or override previously approved experiences. The user's supplied reference order is captured below **separately from** the older `[IMG-01]–[IMG-26]` numbering in `GNARLY_Creative_Universe_Master_Specification.md`. They may not correspond 1:1.

| Reference in this message | Asset name (reference only) | Physical pattern observed | Applied design direction |
|---|---|---|---|
| 01 | IMG_1124.jpeg | Vertical interference/screen printing woven into flowing serpentine/black shapes | Xerox: curved biological lattice, toner, VHS shear |
| 02 | IMG_1122.jpeg | Metallic soft-pink, periwinkle, jade marbling in dark pearlescent paint | Liquid: advected enamel, warped cells, small material highlights |
| 03 | IMG_1125.jpeg | High-contrast monochrome printed snakeskin, varied scale size and ink coverage | Xerox and Subcultural: irregular cell edge, print contrast |
| 04 | IMG_1127.jpeg | Red-white-silver sharply refracted glass / shattered mirror tiles | Caustic: wet fissures & chromatic dispersion distinct from Prism Carmine |
| 05 | IMG_1126.jpeg | Dense fine ultraviolet contour strokes flowing over black relief folds | Tectonic: denser sediment curves, filaments under tension |
| 06 | IMG_1128.jpeg | Silver/black fluid pigment pierced by saturated magenta cellular clusters | Liquid: cellular membranes, gloss, interference and bass opening |
| 07 | IMG_1130.jpeg | Cream/black zine halftone with light blue sprayed patches and sharp stellar stencil | Subcultural: stencil holes, print registration, distressed ink |
| 08 | IMG_1129.jpeg | Teal mirrored porous tunnel with actual spatial depth and holes | Vector Drift: cylindrical perspective, hollow cage and specular rails |
| 09 | IMG_1131.jpeg | Fine moiré/tangential dark olive contour strands with luminous relief seams | Nocturnal and Strata: lithographic dense isolines |
| 10 | IMG_1132.jpeg | Eroded near-monochrome forest-green circular lithograph over aged stock | Nocturnal and Strata: oxidation/patina, eroded rings |

## Root problem confirmed in Stage 68 shader

The visual identity remains dominated by a single `universeEval` fragment/compute evaluator: shapes are analytic and previously used sparse one-dimensional sinusoids, low-frequency noise, or screen-space lines. Theme selection mostly changes color, and the same mathematical vocabulary can make unrelated experiences feel too similar. User liked the improved theme/experience categorization and specifically wants **deeper graphic/material changes**, not a reorganization of controls.

## Technical changes introduced in experimental Stage 71

- New bounded 3-octave fractional Brownian noise, field advection and toner halftone helper functions in `CreativeUniverse.metal`; no extra buffer or external texture.
- **Xerox (look 1):** print plate bent into cellular reptile skin, variable toner coverage, mechanical interruptions and scratch overlays.
- **Subcultural Archive (look 7):** halftone, torn negative space and star stencil arranged as a zine print with transient-driven pressure.
- **Caustic Dissection (look 8):** warped liquid quartz optics, fractured wet surfaces, fake channel dispersion and angular highlights, clearly distinct from **Prism (look 2)**.
- **Tectonic Mesh (look 9):** mineral cross-section, dense contour strata and multiple crossing tensile cables over a bass-opened chasm.
- **Vector Drift (look 10):** perspective-correct-ish inverse-radius cylinder depth, non-planar repeating ribs, hollow cell grid and dark glossy metallic highlights.
- **Liquid Monochrome (look 11):** curved viscous layers, cellular refractive membranes, spectral pearl-like highlights and responsive folds.
- **Nocturnal Lithograph (look 12):** dense lithographic isolines, dual engraving scales, crosshatch, oxidized stone and torn ink.
- **GNARLY Strata (look 13):** weathered eroded relief with concentric/sedimentary fine contours and music-phase modulation.

### Intentionally unchanged
- **Subatomic Bubble (look 3)**; **Jacquard Signal (4)**; **Isometric Chasm (5)**; **Lenticular Wild (6)**; **Prism Carmine (2)**; **Kinematic Compiler (14)**; **Chromatic Organism (15)**.
- No UI rearrangement, routing, download management, audio graph, playback clock, Stems, karaoke, lyric clock or editor migration.
- Both SwiftUI `colorEffect` and Story export **still call the same `universeEval`**, reducing divergence without guaranteeing identical pixels on distinct GPUs.

## Remaining engineering gaps — do not mislabel this as final parity

1. The iPhone 11-era GPU cannot be assumed to sustain 120 FPS with multi-octave noise. Test on real device for thermal throttling and memory, and lower secondary detail under existing EnergyBudget as needed.
2. The updated shaders are still **analytic approximations**: no sampled refracted album bitmap inside a physically traced glass scene; no true persistent fluid simulation, no depth buffer, no CoreMotion-driven quartz normals. These require isolated material kernels / textures and a compositor, not more tint mixing.
3. The full 27-image library is **not yet available in this turn** (only 10 references), so don't invent unseen compositions or change approved assets in their name.
4. A progressive xerox reveal of the **real album cover** is separately prototyped on the Stage 69 experiment branch. Do not pretend the new Stage 71 halftone uses cover pixels, and do not merge 69 implicitly.
5. An actual 3-D tunnel with parallax/geometry requires a raymarched or meshed GPU pipeline. This Stage 71 depth-mapped cylinder is a materially closer intermediate, not a physical scene with a movable camera.
6. Tests are static identity and exporter-raster smoke checks. A/B screenshots, legibility with karaoke, smoothness on physical iPhone, export image-vs-live parity and user sign-off remain required.

## User QA for current references

Test all adjusted looks with the same audio track and at least two contrasting themes. Compare Off / Fluid / Reactive modes. Check 15s Story export for accurate material and bright/dark details. Reject any look that appears like cheap scrolling lines or if changing themes only alters hue. Validate safe areas, player legibility, GPU power budget and no freezes. Preserve the best-performing Stage 70 build until confirmed.

## SwiftUI Expert review notes

Keep frequently changing shader inputs local to the `TurbulentMarbleView` animation subtree; don't update screen-wide `@State` for FFT samples. Use the existing `TimelineView` and `EnergyBudget`. Shader mathematically samples the timestamp, does not create `Timer`, CPU raster loops, view-wide `Canvas` invalidations, or an extra AVAudioEngine. Physical FPS and Instruments traces are needed before promotion.
