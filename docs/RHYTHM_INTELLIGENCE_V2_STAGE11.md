# Stage 11 — Rhythm Intelligence v2

## Why
v1 estimated tempo from intervals between onsets taken from the ~12 Hz visual
envelope (83 ms hop). Every interval became a multiple of 83 ms, so tempos that
are not hop multiples were wrong with high confidence (128 BPM → 120 BPM at
~0.96, beat grid drifting ~2 s per minute). The unit tests only used
hop-multiple tempos, so they could not catch it.

## Algorithm (RhythmAnalysisResult.algorithmVersion = 2)
1. **Onset strength** — log-magnitude spectral flux with window 2·H and hop H
   (256 samples ≤ 24 kHz, 512 ≤ 50 kHz, 1024 above; ≈ 11–16 ms), computed per
   channel and summed (no anti-phase cancellation), detrended by a ±0.25 s
   moving average, half-wave rectified, normalized by its standard deviation.
2. **Tempo** — autocorrelation of the centered onset strength over 55…210 BPM,
   weighted by a log-Gaussian prior (120 BPM, σ = 1 octave), parabolic
   sub-frame interpolation of the peak.
3. **Beats** — dynamic-programming tracking (Ellis 2007, tightness 100):
   beats follow small tempo drift instead of a rigid grid; sub-frame refinement
   on the onset curve.
4. **Downbeat** — 4/4 assumption: the bar phase whose beats carry the most
   low-band (< 150 Hz) energy; `downbeatConfidence` is its margin over the next.
5. **Confidence** — periodicity (ACF at the tempo), beat vs off-beat contrast,
   inter-beat stability. Below 0.25 (`insufficient`) **no beats are published**.

The rhythm stage decodes the source once more (energy is never recomputed) and
is bounded by the energy timeline's coverage. Cached v1 rhythm is discarded by
version; the energy timeline is kept.

## Validation before porting
A Python prototype of exactly this pipeline, on jittered (±10 ms) click tracks:

| Input | BPM found | Median / p95 beat error | Confidence |
|---|---|---|---|
| 124 BPM, 44.1 kHz | 123.73 | 1.8 / 3.9 ms | 0.99 |
| 128 BPM, 44.1 kHz | 128.17 | 2.3 / 3.8 ms | 0.99 |
| 140 BPM, 44.1 kHz | 139.80 | 2.2 / 3.8 ms | 0.99 |
| 174 BPM, 44.1 kHz | 173.90 | 2.3 / 4.0 ms | 0.98 |
| 128 BPM + off-beat hats | 128.10 | 2.2 / 4.0 ms | 0.86 |
| 128 BPM, 16 kHz | 128.23 | 2.9 / 4.6 ms | 0.99 |
| White noise (6 seeds) | — | — | 0.11–0.18 (no beats) |
| Silence | — | — | 0 |

Downbeat phase was correct for accents on beats 0, 1, 2 and 3 (confidence
≈ 0.77). Known ambiguity: at 16 kHz a 174 BPM track can resolve to 87 BPM; both
octave hypotheses are kept in `bpmCandidates`. Real music has not been
measured; synthetic clicks are the best case.

## RhythmFrame
`RhythmFrame.at(sourceTime, in: rhythm)` — pure function: beat index, phase
(0..<1), time since beat, local BPM, beat strength, bar beat/phase (when
downbeats exist), confidences and `pulse(decay:)`. Extrapolates at most one
interval past the tracked beats. Same answer in player, Story preview and MP4.

## Not in this stage
No visual consumes `RhythmFrame` yet (Stage 12). Time signatures other than
4/4, tempo changes larger than the tracker's tightness, and swing are not
modeled.
