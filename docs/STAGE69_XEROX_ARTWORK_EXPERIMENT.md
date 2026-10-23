# Stage 69 EXP — Xerox Serpentine: capa verdadeira revelada em retículas

**Isolated experimental branch**: `stage-69-xerox-artwork-experiments`, based on Stage 68 FINAL. Do not replace the GNARLY invitation's approved v66 IPA.

## Rationale

The Stage 65–68 Xerox Serpentine shader animates synthetic scales and toner, but does not reconstruct the actual cover. The user's design request was an animation that gradually **forms the album artwork**, not a single-color approximation.

## Scope in this experiment

- `XeroxArtworkFormationView` displays the exact image from `PlayerArtworkImage` / `NowPlayingArtworkLoader` cache, with deterministic 20×20 halftone cells on a black print plate.
- Exposure follows **original source-media time**, revealing the cover across the first 20% of the song (or a bounded 24s fallback when duration is unknown). The mask is deterministic across backward/forward seeks and export frame order.
- Live route: camera-free Xerox-only layer over the existing shader in `BackgroundLayer`, at an energy-budget-aware 12Hz. No extra decoding each frame.
- Story route: same SwiftUI composition using the **actual Story artwork UIImage**, the identical media-time function and geometry; not a second hand-coded rendering effect.
- Same material-selection predicate in live and Story avoids overlaying the cover atop unrelated experiences or GNARLY modes.
- Null/missing artwork leaves the original Xerox shader visible; choosing personal photo or explicit cover style retains the existing behavior.
- Tests cover reveal timing, monotonic dither exposure, stable thresholds and unknown-duration safety.

## Honest engineering boundaries

- This is **SwiftUI image compositing on top of Metal**, NOT artwork texture sampling in the fragment shader. The same cover pixels and halftone function are used by live and Story, but encoded pixel parity remains to be tested.
- The cover reveal is a progressive still image; it is not real-time computer vision, mesh reconstruction or automated crop editing.
- Studio-quality matching of toner/noise, anti-aliasing and exact presentation across a physical iPhone and the rendered MP4 is not yet proven.
- The real cover may be a low-resolution video thumbnail if the track metadata lacks higher-resolution album art; don't claim upscaling.
- The built-in audio engine, Stems, karaoke, capture camera and other themes are unchanged. No new network client or GPU resource pipeline.

## Physical & CI acceptance

1. Compile and run `XeroxArtworkFormationTests` and visual catalog smoke suite.
2. On iPhone, play a track with a recognizable human/photo album cover and activate Xerox Serpentine in marble mode, with no selected competing experience; watch the cover progressively form during the first fifth.
3. Pause and seek backward and forward. The cover must replay deterministically at the same playback position; no flicker or off-axis crop.
4. Export two 15s Story clips from 0% and 50% of the song; confirm actual artwork pixels (not flat averaged hue), portrait orientation and no white flash.
5. Change cover to a missing/invalid URL; ensure original shader remains visible without crash.
6. Test thermal overhead, CPU/GPU cadence, low power mode, background/foreground, headphones and player continuity.
7. Only promote as Stage 69 FINAL and republish IPA after device verification. The Stage 68 FINAL branch and user's invitation are not changed by this experiment.
