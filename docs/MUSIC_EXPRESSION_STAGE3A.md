# Music Expression — Stage 3A: contracts and independent cache

## Scope and status

**Contract-only release.** There is no `MusicExpressionEngine` runtime, no
`KeyAnalyzer`, `MelodyAnalyzer`, `SectionDetector`, or mood estimator.
No audio decoding, FFT, Core ML, heavy models, dependencies, player changes,
queue changes, karaoke integration, shaders, export/UI integration, or
automatic background tasks were added by this stage.

Existing Music Intelligence Foundation and Rhythm Stage 2 remain untouched.

## Ownership and future graph

```
AudioAssetDescriptor (canonical identity, full SHA-256 revision, duration)
      ├── MusicIntelligenceEngine → MusicAnalysisCache [existing]
      └── future MusicExpressionEngine → ExpressionCache [contracts only]

      Future Creative Engine (explicit consumer; not wired here)
```

The expression API uses `AudioAssetDescriptor` only as a shared source
identity. `MusicExpressionResult` is a separate immutable `Codable`,
`Equatable`, `Sendable` value; it stores no energy FFT or rhythm results.

## Contracts

`ExpressionCapability`: `key`, `sections`, `melody`, `moodHints`.

`ExpressionCapabilityStatus`: `notRequested`, `pending`, `available`,
`failed(reason)`. Partial snapshots can expose available key while sections
are still pending. A capability's failure does not imply other failures.

Every result carries `ExpressionProvenance`:
- method identifier, explicit `ExpressionFingerprint` algorithm version,
- a dependency-version dictionary (e.g. chroma or rhythm, if consumed),
- analyzed-through media timestamp in ORIGINAL source seconds,
- heuristic confidence within 0...1.

`KeyAnalysisResult`: ordered tonal hypotheses (pitch class, major/minor
mode, confidence); empty hypotheses mean unknown. Relative major/minor
ambiguities can be preserved. `key` and `scale` are optional accessors,
not assumptions of a definitive key.

`SectionAnalysisResult`: ordered, non-overlapping time intervals with
unknown/intro/verse/chorus/bridge/buildup/instrumental/outro labels and
confidence. Gaps are legal. Detecting a boundary does not require a label.

`MelodicFeatures`: optional phrase intervals, relative contour,
mean intensity and confidence. No note/pitch inference occurs.

`MoodHintsResult`: observed descriptive dimensions (brightness, dynamic
range, rhythmic density) with evidence IDs and confidence; **no emotional
classification, mood-to-color policy, typography setting or preset choice**.

All types validate finite values, durations, statuses and applicable ranges
prior to persistence. An `available` capability may validly have an empty
list of detections. It may not have a missing payload.

## Cache behavior

`ExpressionCache` uses its own system `Caches/MusicExpression` directory.
It writes one `assetID-hash + capability` JSON file per capability.
Atomic writes are scoped to a **single capability**; concurrent independent
writes cannot overwrite each other's bytes. Total on-disk cache is limited
to 32 MiB with least-recently-touched eviction, subject to OS eviction.

`load(for:requiring:)` requires the future caller to supply the exact
algorithm and dependency versions for each requested capability. Entries
with another algorithm version or dependency version are misses for **only
that capability**. Unrequested capabilities stay `notRequested`, even if
a valid record exists. A malformed, wrong-source or inconsistent entry
is discarded individually. Source identity includes the SHA-256 revision
captured in the supplied `AudioAssetDescriptor`.

`store(_:for:)` validates a snapshot and persists each available
capability, even when other capabilities are pending. Pending, failed and
notRequested values are not persisted as permanent negative results and do
not erase previously available independent entries. Explicit
`invalidate(_:for:)` targets selected expression capabilities only.

The future expression service must construct and revalidate a fresh
`AudioAssetDescriptor` (including source content SHA-256) and protect the
source against change during analysis, as MusicIntelligenceEngine does.
This cache does not read, decode or rehash audio itself. Actors serialize
cache operations but **do not schedule/deduplicate analysis jobs**; that
requires a separate future engine/coordinator and is not claimed here.

A file replacement at the same path with a different revision invalidates
all expression records for that asset. If an energy or rhythm algorithm
changes, only expression capabilities that declare that version dependency
miss their cache. This stage does not modify MusicAnalysisCache or its
schema, paths or version.

## Verification

- Immutable contract and Codable round-trip tests for pending, failed,
  unknown key, alternative key hypotheses, sections, melodic features,
  mood evidence, and invalid/non-finite payloads.
- ExpressionCache persistence across actor instances; partial snapshots;
  version and dependency misses; wrong source revision; individual
  corruption and invalidation; concurrency of independent writes.
- Regression check that a previously persisted MusicAnalysisCache energy/
  onset result survives expression writes and invalidations unchanged.

Validate with the existing XcodeGen project and macOS Actions:
`xcodegen generate`, simulator XCTest suite, unsigned Release build and IPA.
No performance measurement or music accuracy claims are made in Stage 3A.

## Next stage, explicitly NOT implemented

A future Stage 3B may introduce a native vDSP chroma analysis and classical
key-profile classifier. Existing three-band FFT visual envelopes do **not**
contain enough pitch-class information to determine musical key. No GPLv3
KeyFinder code or Python/ML checkpoints are imported by this stage.
