# NightcoreLab — Stage 15B: Creator Preset Sharing Foundation

## Scope and baseline

Builds on the merged/audited Stage 14B + 15A. **Extends** the existing `CreatorPreset` Codable v1; does not alter its schema, replace `CreatorPresetStore`, create a second visual preset system, modify `StoryFrameRenderer`, or extend the video `SharePackage`.

## Codable audit

| Component | Before Stage 15B | Sharing decision |
| --- | --- | --- |
| `CreatorPreset` | Codable v1: experience/material IDs, TypographyPreset, CreatorControls, ExportProfile | Keep byte-compatible local schema |
| `CreatorPresetStore` | Single local UserDefaults JSON key, schema v1 | Keep local save/load independent of imports |
| `ExportProfile` | Codable 9:16/1:1/16:9, quality, crop enums | Validate vocabulary; fallback unknown enum values only |
| `TypographyPreset` | Codable style, reaction, intensity, mapping, seed, font | Decode whole preset; fallback malformed/unknown typography to existing Neon |
| `VisualMaterialCatalog` | Known authored material IDs | Imported unknown material → Original Marble |
| `CreativePresetCatalog` | Curated experiences + legacy recipes | Imported unknown experience → Original |
| `CreativeExperienceResolver` | Existing experience → material and composition path | Unchanged |
| `SharePackage` | MP4, JPEG, JSON metadata for videos | Unchanged; portable preset is a standalone JSON file |

## Architecture

```
Creator Studio (existing)                     Files, AirDrop, Mail, Messages
  |                                                 ^
  v                                                 |
CreatorPreset v1  ---> CreatorPresetPackage v1 -> .json
  ^                                                 |
  |                                                 v
explicit Apply <- CreatorPresetImportPreview <- CreatorPresetPackageMigration
  |                                                 ^
  v                                                 |
CreatorPreset.applying(to:) <- sanitized v1 package <- Files document picker
  |
CompositionRuntime + CompositionLayoutPolicy
  |
StoryExportCanvas / StoryFrameRenderer (existing)
```

Native SwiftUI `ShareLink(item: URL)` opens the system share sheet. Native `fileImporter` with `UTType.json` uses the system document picker. Security-scoped external file URLs are opened temporarily and access is released after reading. Imported files are never executed, and the importer does not contact a server.

## CreatorPresetPackage JSON v1

Package fields are intentionally **flat** and contain only public creative settings:

```json
{
  "schemaVersion": 1,
  "name": "Night Drive",
  "author": "Anônimo",
  "createdAt": "2026-10-13T00:00:00Z",
  "experienceID": "cyber-night",
  "materialID": "liquid-glass",
  "typography": {
    "style": "magazineCutout",
    "audioReaction": "off",
    "effectIntensity": 0,
    "audioMapping": {},
    "deterministicSeed": 0,
    "font": "classic"
  },
  "controls": {
    "materialIntensity": 0.5,
    "distortion": 0.5,
    "brightness": 0.5,
    "movement": 0.5,
    "typographyScale": 0.5,
    "glow": 0.5,
    "kineticAmount": 0.5,
    "beatSensitivity": 0.5,
    "energyResponse": 0.5
  },
  "exportProfile": {
    "aspectRatio": "landscape",
    "quality": "high",
    "cropPolicy": "aspectFit"
  }
}
```

Note: `typography.audioMapping` above is illustrative; the actual file uses the existing `TypographyAudioMapping`'s native Codable fields. **Always use the encoder**, rather than hand-authoring the mapping section.

No audio URLs, artwork URLs, local file paths, device identifiers, account IDs, search history or login data. `author` is an optional user-entered public label, not an automatically collected account profile. Default is "Anônimo". Dates use explicit ISO8601 and are normalized to seconds for equality.

## Export / sharing

1. Choose experience, material, typography, controls and `ExportProfile` in Creator Studio.
2. Optionally enter package name and public author. Tap **Exportar JSON**; the app serializes the currently selected immutable preset into a temporary `NightcoreLab-CreatorPreset.json`.
3. Tap the system **Compartilhar** action. Files, AirDrop, Messages and Mail may be shown depending on device capabilities and installed apps.
4. After changing any creative selection, the prepared URL is invalidated: regenerate the JSON before sharing a changed preset.
5. Save CreatorPreset locally via the existing **Salvar CreatorPreset** button independently of the exported JSON.

Temporary files use a UUID directory, a fixed basename, and atomic writes; user-entered metadata never influences filesystem paths.

## Import, validation and fallback

1. Tap **Importar**, select a JSON file in the system Files picker.
2. Validate that the file is local, readable, nonempty and no larger than **256 KiB**.
3. Inspect the top-level schema before decoding. **Only schema v1 is accepted.** Unknown schema versions throw a specific error; future versions are not guessed.
4. Validate all nine `CreatorControls` with existing normalized bounds `[0,1]`; invalid/nonnumeric data is rejected.
5. Repair only *known vocabulary mismatches* and expose warnings:
   - Unknown experience → existing `original`.
   - Unknown material → existing `original-marble`.
   - Unsupported or undecodable typography → existing Neon, with its canonical safe mapping.
   - Unknown aspect/quality/crop values → `portrait`, `balanced`, `safeAreaPreserving`, respectively.
6. Decode the repaired typed `CreatorPresetPackage`. Validate its public labels, createdAt, controls and all required fields. Reject malformed JSON or unsupported schema.
7. Display the package name, author, selected experience, material, typography, format and quality in a **read-only preview** using existing `StoryExportCanvas` and `StoryFrameRenderer` paths. Show all fallback warnings.
8. Nothing changes in the active Creator Studio or in `CreatorPresetStore` until **Aplicar** is tapped. Apply freezes a normal `CreatorPreset` session; saving persistently remains a separate explicit choice.

An untrusted import never selects a missing shader or forces an unsupported local typography font. User-entered metadata limits are name 80 characters and author 60 characters; path separators and control characters are prohibited.

## Migration strategy

`CreatorPresetPackageMigration.decode(_:)` is the single version dispatcher. At present it accepts v1 only. A future v2 may add a **new explicit case** that converts its fields to the existing normalized in-memory `CreatorPreset` representation. Do **not** silently reinterpret `schemaVersion: 2` as v1, mutate local `CreatorPreset.version`, or invent a v2 schema prematurely. Structural corruption and invalid numeric controls remain failures, not silent downgrades.

## Tests

`CreatorPresetSharingTests` covers:
1. Flat v1 encoding, public fields and absence of private keys.
2. Typed decode / exact round trip and preserved seeded typography.
3. Unknown experience fallback.
4. Unknown material fallback.
5. Unknown typography fallback.
6. Unknown export values fallback.
7. Unsupported version and incomplete data handling.
8. Out-of-range controls rejection and oversized file rejection.
9. JSON filesystem export/import with export profile intact.
10. Read-only imported preview and pixel equality with existing `StoryFrameRenderer`.

Keep existing `CreatorControlTests`, `AdaptiveCompositionLayoutTests`, `ShareExportPipelineTests`, player, karaoke and material tests as regression gates. Gate the PR on `xcodegen generate`, XCTest, Release and IPA.

## References and limitations

Studied architectural separation only from [projectM](https://github.com/projectM-visualizer/projectm) (presets vs renderer), [Astrofox](https://github.com/astrofox-io/astrofox) (portable audiovisual project workflow), and [BetterLyrics Composer](https://github.com/better-lyrics/composer) (composition/configuration UX). No reference code or dependencies are copied.

- iOS 17+ native share/file APIs only; available destinations depend on installed system services.
- Only curated/legacy IDs can currently be imported. Not a marketplace and not a mechanism to distribute arbitrary shaders, code, audio, compositions or custom runtime engines.
- No QR codes, deep links, cloud, accounts, backend, plugins, MIDI, AUv3 or new export codec.
- Imported preview is a frozen visual sample; it does not preview external audio playback or guarantee device-specific Share Sheet destinations.
- The current local UserDefaults save supports a single selected preset; this stage does not introduce a browsable multi-preset catalog.
