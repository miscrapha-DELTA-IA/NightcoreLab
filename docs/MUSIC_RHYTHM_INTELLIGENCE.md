# Music Intelligence — Stage 2: Rhythm Intelligence Layer

## Architecture

`AudioAssetDescriptor` → `AnalysisScheduler` → `MusicIntelligenceEngine`
→ `MusicAnalysisResult` → `MusicAnalysisCache`.

The unchanged `AudioFeatureAnalyzer` and `AudioFFTSpectrum` decode audio
once into a ~12 Hz energy + three-band spectral timeline. The rhythm analyzer
consumes **that same timeline**; there is no second FFT, audio graph, tap,
playback mutation, new runtime dependency, or UI integration.

`MusicAnalysisResult.capabilities` now supports:
- `energy`: FFT-backed timeline, original algorithm v1;
- `onsets`: original Foundation energy-rise heuristic, algorithm v1;
- `rhythm`: independent spectral flux/onset/BPM/grid analysis v1.

Statuses are `notRequested`, `pending`, `available` and `failed(reason)`.
An unavailable rhythm analysis does **not** affect energy or existing onsets.
Callbacks remain ordered immutable capability snapshots, delivered on the
scheduler actor, NOT the main actor. In-flight consumers still share a single
work item and detach independently on cancellation.

## Algorithm

`RhythmAnalyzer.analyze(timeline:)` is deterministic:
1. Form a novelty curve from *positive changes* in bass/mid/treble magnitude
   and RMS energy. Foundation's boolean onset is supplementary evidence.
2. Find local positive peaks above a local mean/deviation threshold, enforce
   an absolute floor and 200 ms refractory spacing. Silence produces no events.
3. Vote for multiple lag-derived tempo hypotheses in 55–210 BPM, including
   octave alternatives. Score each candidate by agreement of observed onset
   intervals with integer multiples of its beat period. Keep up to 4 candidates.
4. For sufficient periodicity evidence (confidence >= 0.50), emit a bounded
   regular beat grid in the original source timeline. Each beat has a
   proximity-to-attack strength to distinguish measured accents from inferred
   markers. A weak pulse yields no predictive grid.

`RhythmAnalysisResult` contains the observed `onsetEvents`, ranked
`BPMCandidate(bpm, confidence)`, `BeatEvent(time, index, strength)` grid,
aggregate confidence, method identifier, algorithm version, and quality tier.

These are **heuristics**, not ground-truth beat tracking: half/double-time
ambiguity is preserved (e.g. 80 and 160). Short tracks, syncopation, tempo
changes, low-volume material, and free-tempo performances can lower confidence.
The model currently offers a **single candidate grid**, not piecewise tempo
segments, and MUST NOT be represented as a calibrated BPM meter.
No grid is produced when confidence is insufficient. A future consumer must
use beat strength/quality when deciding whether to animate.

## Cache and compatibility

The root energy/onset `schemaVersion = 1` and `analyzerVersion = 1`
remain unchanged. `rhythmAnalyzerVersion` is separate and can increase
without recomputing energy, FFT bands, or the original onset capability.

Older JSON entries without rhythm keys decode as `notRequested` with a
legacy version. `MusicAnalysisCache.load` rejects corrupted/inconsistent
entries as before; for *only* a rhythm-version mismatch, it returns an immutable
snapshot with rhythm cleared while preserving energy/onsets. The engine
recomputes rhythm alone and atomically persists the new terminal result.
Failed rhythm calculations are persisted beside valid energy, then retried
on the next request. Cache write failures cannot invalidate analysis.

Cached source identity is still checked using a full SHA-256 content digest;
a source replaced at the same URL cannot accidentally reuse old beats.
Coverage never extends beyond the analyzed prefix (maximum 20 minutes).

## Future consumers (not wired yet)

- Typography: `rhythmAnalysis.beatGrid` and `BeatEvent.time` can align
  a word transition in original source time.
- Visual Presets/Shaders: `BeatEvent.strength` and per-candidate confidence
  can control visual intensity, optionally gated on `quality`.
- Share Export: beat markers remain deterministic media timestamps, matching
  the existing preview/export time resolver.

No stems, vocal analysis, pitch detection, karaoke scoring or ML models.

## Complexity, cost and risks

- Additional O(N) scan and O(N * 3 * 3) bounded lag voting on the already
  stored 12 Hz timeline, plus a bounded grid (<= 5,000 beats).
- No second file decode or FFT; 1 MiB chunked SHA-256 checks remain the main
  cache-hit file I/O cost, as in Stage 1. The scheduler still defaults to one
  utility worker and supports shared work and cancellation.
- Rhythmic events are quantized by the existing ~83 ms analysis hop, and
  resulting BPM estimates can wobble by several BPM. There is no live tempo
  following or adaptive multisegment tempo map.
- Device energy, CPU and battery performance have not been benchmarked on
  physical hardware. No measured speedup or accuracy claim is made.

## Validation

`RhythmAnalyzerTests` checks silence, periodic 80/160 BPM ambiguity,
tempo changes, low-level non-events, independent rhythm cache invalidation,
recoverable rhythm failures and concurrent same-asset requests.
Existing Foundation, FFT, visual preview/export timestamp tests must still pass.

Run `xcodegen generate`, the simulator XCTest suite, and an unsigned Release
build using the existing `Build Unsigned IPA (Free Route)` GitHub workflow.
