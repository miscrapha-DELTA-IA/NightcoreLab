# Rhythm Real-World Validation (Stage 12.5)

Goal: measure Rhythm Intelligence v2 on representative music before trusting
it for the Marble pulse, and change the algorithm only where the measurements
show a failure. Result: **v3** (`RhythmAnalysisResult.algorithmVersion = 3`).

## Method

No audio is committed. Two sources of evidence:

1. **Genre fixtures** — deterministic synthetic arrangements with known beat
   times (`NightcoreLabTests/RhythmGenreFixtureTests.swift`):

   | Fixture | What makes it hard |
   |---|---|
   | EDM 128 / 140 | kick on every beat, snare on 2/4, 16th hats, off-beat bass, pad |
   | House 124 / 128 | **loud open hat on every off-beat** (more broadband flux than the kick) |
   | Rock 120 / 150 | kick 1/3, snare 2/4, ±8 ms timing, ±1.5 % slow tempo drift, square-wave guitars |
   | Hip hop 90 / 75 | syncopated kicks, heavy snare, **swung** 16th hats, 808 |
   | Ramp 100→130 | tempo changes 30 % over 40 s |
   | No drums | sustained chords, soft attacks, rubato changes (3 seeds) |
   | Silence | — |

2. **Real tracks (optional, local)** — `testRealTracksWhenProvided` runs when
   `TEST_RUNNER_NIGHTCORE_RHYTHM_FIXTURES` points to a folder with
   `manifest.json` (`[{"file": "song.m4a", "bpm": 128, "drums": true}]`).
   It prints BPM / confidence / downbeat confidence, fails on a non-octave
   tempo error and on a high-confidence pulse for a drumless track. It is
   skipped in CI (no licensed audio in the repository).

Metrics: BPM; confidence and quality; **phase stability** = share of true
beats with a tracked beat within ±50 ms, median phase error, and the
coefficient of variation of tracked inter-beat intervals.

The algorithm was changed in the NumPy reference prototype first, then
ported 1:1 to `RhythmAnalyzer`. The table comes from the prototype run on a
mirror of the Swift fixture generators (same LCG noise, same constants).

## Results (v2 = Stage 11, v3 = Stage 12.5)

| Fixture | v2 BPM | v2 conf | v2 beats ±50 ms | v3 BPM | v3 conf | v3 beats ±50 ms (median) | v3 ibiCV |
|---|---|---|---|---|---|---|---|
| EDM 128 | 63.9 ✗ | 0.77 | 49 % | **128.5** | 0.78 | **100 %** (2.3 ms) | 0.008 |
| EDM 140 | 69.9 ✗ | 0.78 | 49 % | **139.8** | 0.79 | **100 %** (2.3 ms) | 0.005 |
| House 124 | 123.6 | 0.75 | **0 %** ✗ (off-beat) | 123.6 | 0.99 | **100 %** (3.9 ms) | 0.011 |
| House 128 | 63.9 ✗ | 0.75 | 0 % ✗ | **128.4** | 0.99 | **100 %** (3.5 ms) | 0.011 |
| Rock 120 | 60.2 ✗ | 0.84 | 49 % | **120.2** | 0.73 | **100 %** (1.6 ms) | 0.017 |
| Rock 150 | 75.5 ✗ | 0.82 | 50 % | **150.7** | 0.65 | **100 %** (2.3 ms) | 0.022 |
| Hip hop 90 | 179.0 ✗ | 0.99 | 100 % | **90.2** | 0.80 | 100 % (1.9 ms) | 0.006 |
| Hip hop 75 | 74.9 | 0.79 | 100 % | 150.2 (octave) | 0.93 | 100 % (1.7 ms) | 0.010 |
| Ramp 100→130 | 63.5 | 0.29 | 49 % | 63.5 | 0.29 (low) | 49 % | 0.085 |
| No drums (seed 5) | 117.3 | **0.46** ✗ | — | 117.3 | **0.18** (no beats) | — | — |
| No drums (seed 10) | 69.8 | **0.60** ✗ | — | 143.4 | **0.14** (no beats) | — | — |
| No drums (seed 11) | 117.4 | 0.39 ✗ | — | 117.4 | **0.16** (no beats) | — | — |
| Silence | — | 0.00 | — | — | 0.00 | — | — |
| Click 124/128/140 (existing tests) | correct | 0.99 | 100 % | correct | 0.99 | 100 % (≈2 ms) | — |
| Click 174 @ 16 kHz | 87 or 174 | — | — | 174.1 | 0.99 | — | — |

Sample rate: the same EDM / house / rock / hip hop fixtures at 44.1 kHz
(hop 512) give the same BPM and 100 % of beats within 50 ms.

✗ = what v2 got wrong. "No drums" with confidence ≥ 0.25 means v2 published
a beat grid and the Marble pulsed on music without a pulse.

## What changed (and the evidence for each change)

1. **Octave correction** after the prior-weighted ACF pick: below 80 BPM move
   to the half lag, above 160 BPM to the double lag, when that lag keeps at
   least 50 % of the periodicity (at most two steps). Evidence: kick/snare
   patterns repeat every two beats, so ACF at 2 beats exceeded ACF at 1 beat
   (EDM 0.889 vs 0.484, rock 0.405 vs 0.231); swung hats made 179 win for
   hip hop at 90.
2. **Doubling check on the tracked beats**: when half-beats are as strong as
   beats (beat/half-beat ratio < 1.4 in both the full band and the < 150 Hz
   band, or in either band below 80 BPM), insert the half-beats. Evidence:
   rock seeds whose ACF ratio stayed below 50 % (0.37–0.44) and a 174-BPM
   click that the prior placed at 87.
3. **Phase check**: when the low-band (kick) flux on the half-beat is more
   than 2× the flux on the tracked beats, shift the grid by half a period.
   Evidence: house off-beat hats have larger broadband flux than the kick;
   the low-band ratio was 13.4 for house and ≤ 0.8 for every other fixture.
   Needs a new per-frame low-band flux in `OnsetEnvelope` (`lowFlux`).
4. **Contrast**: beat/off-beat contrast is the larger of the full-band and
   low-band ratios, and confidence is multiplied by `min(1, 0.4 + 4·contrast)`.
   Evidence: drumless fixtures had contrast 0 with periodicity up to 0.73;
   all drum fixtures had contrast ≥ 0.15.

Unchanged: onset envelope, ACF and prior, DP tracking, downbeat estimate,
quality thresholds, the "no beats below 0.25" rule, `RhythmFrame`, and the
Marble pulse weighting.

## Known limits (documented, tested)

- **Tempo ramps**: a 30 % ramp has no single period. v3 locks on half tempo
  with confidence 0.29 (`low`), so the Marble pulse is weighted by ≈ 8 %.
  `testTempoRampIsNotReportedAsHighConfidence` guards that it never claims
  `high`. Real songs with gradual drift (rock ±1.5 %) are tracked correctly.
- **Octave ambiguity** stays inherent: slow hip hop (75 BPM) is reported at
  150 with every real beat tracked (the pulse lands on the 8ths). Alternates
  remain in `bpmCandidates`.
- **4/4 assumption** for downbeats (unchanged).
- Real recordings were not available in this environment; the optional
  real-track test is the path to confirm on a device or a Mac.

## Cache

`algorithmVersion` 2 → 3 and `methodIdentifier` `…-v3`: cached v2 rhythm is
recomputed on next use; the energy timeline is kept (no FFT re-run), as
covered by `testStaleRhythmRecomputesWithoutReanalyzingEnergy`.
