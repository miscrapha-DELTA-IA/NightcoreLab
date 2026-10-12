# Stage 7 — Creative Preset Authoring Layer

## Architectural decision

Stage 7 is a **data and local persistence** layer above the pre-existing:
`CreativePreset`, `VisualPreset`, `CreativeVisualProgram`,
`VisualComposition`, `TypographyPreset`, and `CreativeSnapshot`.
Nothing is rendered or activated merely by loading a package.

```
                     CreativePresetPackage v1
                     /        |          \
  VisualPreset (validated) TypographyPreset   PreviewMetadata
                     \        |          /
                VisualComposition
            / CreativeVisualProgram \
     PresetLayer / Keyframes / AudioBindings
                     |
    CreativePresetAudioMapping (derived reference only)
                     |
              CompositionFrameResolver (unchanged)
```

The `composition` is authoritative for all visual program rules and
layer audio bindings; `visualPreset` is a checked projection of the
existing `composition.program.preset.visualStyle`. `audioMapping` is
a derived index of available `CreativeSignal` values and where the
existing bindings live. **Neither duplicates nor executes equations.**
`typographyPreset` is kept independently to retain its optional
reaction setting, while the actual legacy typography style must match
the embedded program's style. There is no second renderer.

## Package contract and compatibility

`CreativePresetPackage` includes:
- `id`, `schemaVersion` (currently 1), `name`, `author`
- `visualPreset` and `typographyPreset`
- `composition` with all original rules, layer IDs, keyframes, timeline,
  audio bindings and deterministicSeed
- `audioMapping` derived from the embedded CreativeVisualProgram/LayerAudioBinding
- `previewMetadata`: description, elapsed preview timestamp and typed
  canvas preference; **none of these alters the existing MP4 exporter**.

Both encoding and decoding use Codable. Decoding rejects unsupported
versions, mismatched IDs/names, contradictory audio-mapping references,
invalid preview coverage, and mismatches with the embedded visual preset.
For early v1 drafts, missing *derived* descriptors are reconstructed
from the composition. Missing compositions cannot be reconstructed
safely and are rejected. Unknown future versions are not silently
downgraded, migrated or removed from disk.

The four built-in presets (`original`, `bass-pulse`, `night-drive`,
`soft-flow`) are wrapped from **existing** `CreativePresetCatalog.all`
programs, preserving their exact rules, themes, typography, audio
reaction, and render result. They use a neutral 0–15s template timeline
for packaging only, NOT the live audio timeline. Existing
`CreativePresetCatalog.program(for:)` and `effectiveProgram(...)`
stay unchanged.

## Local authoring catalog

`CreativePresetPackageStore` is an actor:
- Application Support / NightcoreLab / CreativePresetPackages;
  private, offline storage (NOT the audio cache or user defaults)
- atomic per-package JSON writes; file names are SHA-256 digests of
  package IDs, not user-generated paths
- maximum 512 KiB per package; malformed/oversized/unsupported files
  never become an activated creative program
- built-in IDs are reserved; no replacement or deletion allowed
- listing skips invalid user packages, retains unsupported files for
  future migration, sorts user entries by stable ID
- exact selection or **explicitly marked** fallback to Original:
  `CreativePresetCatalog.resolvePackage(id:from:)`.
- `availablePackages(from:)` returns built-ins first, then user packages.

No CloudKit, network, editing UI, downloads or marketplace are created.

## CreativeSnapshot preparation

`CreativePresetPackageSnapshot.capture(...)` freezes the **full**
authoring package with the existing `CreativeSnapshot` visual state.
It validates that the captured `CreativePreset` actually matches the
package program before rebasing its timeline to current playbackTime
and playbackSpeed. The program, composition layers, bindings,
typography configuration, seed and author remain unchanged.

This is an opt-in handoff, not a replacement for `StoryVideoRequest`,
`StoryFrameRenderer`, or the existing export flow. When a future
feature enables package selection, its consumer must deliberately
construct a source-specific frozen composition using the real audio
timeline, not apply the neutral catalog template.

## Test coverage and limitations

`CreativePresetPackageTests` covers round-trip, schema rejection,
catalog parity for all four built-ins, missing derived fields,
corrupted or contradictory JSON, deterministic frame parity,
persistent local storage, protected built-in IDs, sorted merging and
explicit fallback, snapshot rebasing and storage-budget rejection.

Performance: reading/writing occurs only when the package API is
explicitly called. There is no change in the frame resolution hot
path, FFT, decoder, renderer or player. Local package size is bounded;
catalog enumeration is file I/O and should not run on the audio thread.

Risks: schema v1 has no arbitrary future migration, multi-device sync,
or external package signature validation. The audio-mapping index must
always be derived from the composition and validated when decoding.
Profile and preview hints are descriptive, not a promise of a new
video format. The store does not automatically apply user presets.

CI: XcodeGen, XCTest simulator tests, unsigned Release and IPA.
