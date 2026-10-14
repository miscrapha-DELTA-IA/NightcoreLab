# EXP-8 — Stage 17E.1: opt-in karaoke scoring

## Data and lifecycle

`AudioEngineManager` owns the only live AVAudioEngine. Explicit microphone
activation requests permission and switches its session to playAndRecord.
The player is paused/rescheduled at its saved source position while the route
changes; the input is never connected to the speakers. Disabling capture
removes the tap, destroys its mailbox, restores playback category and resumes
music if it was playing. Track replacement, dismissal, background, interruption
and output removal end capture. Permission requests have generation guards.
Use headphones: this lightweight detector does not perform source separation
or acoustic echo cancellation, so speaker bleed can be interpreted as singing.

A preallocated, bounded input mailbox copies/downsamples the latest buffer.
A serial 20 Hz worker estimates RMS and fundamental using normalized
local-peak autocorrelation. No analysis, task spawning or observable state
mutation runs on the audio callback. No recording is saved or uploaded.
Unvoiced/noisy/low-confidence frames do not count as sung evidence.

LyricsStore's existing display driver feeds its separate ScoringSession with
source time plus the lyric calibration offset. EnginePlaybackClock is unchanged.
The HUD reads only this separate Observation leaf at <=15 Hz. Its overlay and
judgment badge do not change the lyrics' layout or scroll policy. Pausing earns
no points; a detected seek starts a new run. Playback completion finalizes the
result before the clock resets or the queue loads another song. A separate
completed snapshot survives auto-next and lyrics loading; its dismissible card
is hosted by NowPlayingScreen, outside the lyrics fade mask. Only a new run or
explicit dismissal clears it.

## Scoring contract

- Word intervals are unioned so overlap cannot double-count. Empty lines and
  explicit word gaps are ignored. Simple LRC only provides line endpoints:
  instrumental pauses inside such an interval cannot be inferred reliably.
- 40% voiced presence/attack (300 ms tolerance), 40% scale consonance and
  optional relative melodic motion, 20% adjacent-frame energy stability.
- Pitch class distance is octave invariant; 35 cents gets full credit, falling
  linearly to zero at 110 cents. Playback pitch transposition is removed first.
- Available, source-validated v1 KeyAnalysisResult/MelodicFeatures are taken
  from ExpressionCache, using the existing off-main descriptor lookup. Evidence
  is frozen per run. A missing/low-confidence key is explicitly labeled
  **rhythm and presence**; the 40/20 observed weights are renormalized to 100%.
  No key, melody or "correct singer note" is invented from the backing track.
- This repo contains expression contracts/cache, not a production key/melody
  extractor. Thus uncached songs currently use the labeled rhythm-only mode.
  AudioFeatureAnalyzer is backing-track evidence, not microphone evidence and
  is deliberately not misused as the singer's envelope.
- 100 base points per source second × quality × multiplier. Accuracy is the
  duration-weighted mean quality, independent of combo. Every three verses
  >=70% increases the multiplier (1x through 4x); a failed verse breaks combo.
- Verse ratings: >=90% PERFEITO, >=75% ÓTIMO, >=55% BOM, otherwise QUASE.
  Final ranks use the same 90/75/55 boundaries (S/A/B/C).
- Simulation is explicit, injectable and labeled on both HUD and share text;
  denying microphone access never silently enables fake singing.

## Verification

Fast-lane selectors retain AudioQualityTests, RuntimeStabilizationTests and the
fast visual contract from the preceding main hotfix. New deterministic tests
run in RuntimeStabilizationTests without microphone permission or hardware:
combo 1–4x and silence break; no scoring in gaps/pause; octave/pitch-shift
invariance; autocorrelation sine/DC/silence; HUD lifecycle and scroll policy;
seek reset; finalization idempotence; simulation labeling.

Device acceptance still requires a physical iPhone with headphones: permission
allow/deny, route restoration, interruption, actual latency and acoustic bleed.
A green simulator CI cannot certify those acoustic/hardware behaviors.
