# Stage 68 FINAL — Visual Language release candidate (v68 / build 68)

Base: `stage-68-visual-language-experiments` at `66452d8ef13612086fd14f94eaff2a1b3d524b9a`.
See `docs/STAGE68_VISUAL_LANGUAGE_AUDIT.md` for the user feedback matrix.

## Scope of the RC
- Three distinct classes in the visual picker: classic color themes, authored material themes and autonomous GNARLY modes.
- Experience selection stays independent from the theme; reactive rhythm remains Off/Fluid/Reactive.
- Stronger theme-material influence and geometry-driven reactions in Nocturnal Lithograph, Liquid Monochrome, Vector Drift 2000, Tectonic Mesh, Caustic Dissection and Subcultural Archive.
- Prism Carmine and Caustic Dissection now use **separate shader branches**.
- Metamorphic Strata rebuilt as an erosion abyss rather than monotonous horizontal bands.
- Original Gnarly + Strata/Compiler/Organism cannot be silently displaced by a saved experience.
- Preserves original shader and looks for Subatomic Bubble, Isometric Chasm, Compiler and Organism; does not rewrite audio engine, karaoke clock, camera recorder or story exporter.
- Stable persisted IDs and existing package decode remain unchanged.
- Version badge updated to v68; CFBundleVersion and XcodeGen release settings updated to 68.
- Existing player badge / unified runtime assertions updated in sync.

## Already verified
The Stage 68 **experimental** SHA `66452d8ef` passed the fast lane workflow, continuity beta, karaoke clean-mode and Share Card test workflows. The fast lane did **not** create an IPA; the final branch must run the full pipeline.

## Outstanding release gates
1. Confirm complete `stage-68-visual-language-final` CI success, including the **Build Unsigned IPA (Free Route)** artifact uploaded and nonempty.
2. Test v68 on **physical iPhone** and check all six reimagined experiences in Off/Fluid/Reactive with 2+ contrasting themes; note continuity, thermal load, audio and animation fluidity.
3. Confirm Prism Carmine visually differs from Caustic Dissection using the same track, and visual selections persist across restart.
4. Verify the Story renderer's visual palette, look and time at the same timestamp as the live shader, and confirm Story video orientation.
5. Check older Gnarly 0–20% cover-phase palette, Subatomic Bubble/Isometric Chasm/Compiler/Organism and camera karaoke preview for regressions.
6. Only after device approval, promote a stable downloadable IPA and change `convite/instalar.html`; it currently points to approved v66.

## Deferred work
- True progressive Xerox Serpentine **album artwork reveal** requires sampling actual cover texture (not the album hue) from the live player and the offscreen Story pipeline, with fallback if missing. Do not claim it is included in v68.
- Persistent geological history, real 3-D particle physics, motion sensors and guaranteed 120 FPS have not been implemented.
- Neither the branch nor the IPA has been merged into main or published as a durable Release automatically.
