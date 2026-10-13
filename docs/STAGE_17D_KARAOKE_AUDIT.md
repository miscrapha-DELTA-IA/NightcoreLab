# Stage 17D — Audit & instrumentation baseline

Based on **exact** commit `c4a0afaeef2101dfb14f53152330961a9227adf4`.
Date: 2026-10-13. No device profiling was performed from this tool environment.

## Confirmed architecture
- `LyricsStore` is the only observable active-line owner. `activeLineIndex`
  and `isPlaying` are published only on discrete transitions; media time is
  read through `EnginePlaybackClock`, never published as a SwiftUI property.
- Active word `TimelineView` resolves typography using source-time and
  `EnergyBudget.visualInterval` (normal 60, Low Power/fair 30, serious 15,
  inactive/critical paused). This admission policy was already present.
- `KaraokeLyricsView` requests scroll in four situations: tap line,
  return-to-live, automatic active-line transition and initial restoration.
  A 0.40s `withAnimation(.smooth)` surrounds scroll; line emphasis has 0.30s
  animation; inactive layout also animates status by 0.30s. These may overlap
  in quick-line passages. This is a **structural overlap risk**, not observed
  GPU jank.
- Active word hot path calls `TypographyLayer.resolve` →
  `TypographyResolver.resolve` → `TypographyAnimationEngine.resolve`,
  recomputing time-dependent fill and animation. `TypographyPreparedLine`
  already caches static seed/look work for each constructed line view;
  construction frequency was previously unmeasured.
- `EnginePlaybackClock` retains source-time correctness and output-latency
  compensation. The existing `LocalPerformanceMetrics` collects bounded
  MetricKit aggregate CPU/GPU/hitches but not per-frame attribution.

## Stage 17D phase 1 (instrumentation only)
New `KaraokePerformanceProbe` is opt-in via launch environment
`NIGHTCORE_KARAOKE_PROFILING=1`, aggregates numeric counts and timing in
memory, and does **not** log song metadata, raw LRC, URLs or audio.
Instrumentation covers effective active-word TimelineView ticks, long tick
gaps relative to configured cadence, typography resolve duration,
active-line changes, scroll requests, mean line-change-to-scroll latency,
requested animation seconds, possible request overlap and prepared-line
constructions. No disk write, network request or UI observer per frame.
It does not purport to measure true CoreAnimation completion or GPU time.

Fixture hypothesis: three rapid lyric lines spaced 180ms apart with
400ms scroll requests produce two *overlap-risk* counts. This is a
deterministic control-flow demonstration, not a real-device baseline.

## Measurements required before declaring any optimization successful
- Launch a debug build with `NIGHTCORE_KARAOKE_PROFILING=1`; obtain
  `KaraokePerformanceProbe.shared.snapshot()` from debugger.
- Play reproducible, rights-cleared or synthetic LRC at 0.5/1/1.5/2x in
  Neon, Magazine, Glitch, Kinetic and Minimal, comparing Marble vs low-cost
  backgrounds; collect before/after snapshots **within the same environment**.
- Capture Instruments Animation Hitches, Core Animation, Time Profiler and
  Metal System Trace on physical hardware. Use existing MetricKit aggregates
  for longitudinal CPU/GPU/hitch trends (they are not per-frame metrics).
- Simulate Low Power/thermal/reduced motion for policy tests; confirm physical
  limits where possible. No claim of improved FPS until measured.

Phase 2 may fix redundant/overlapping scroll based on the confirmed calls
and deterministic fixture. Phases 3/4 are conditional on profiling.

## Stage 17D phase 2 — structural fast-line reproduction and scroll coordination

The test fixture reproduces the *request overlap risk*: three consecutive
0.18-second lyric starts cannot accommodate successive 0.40-second scroll
animations. **This is not a measurement of actual device stutter.** A pure
`KaraokeScrollPolicy` now suppresses repeated target requests and performs
instant reposition for seek, restoration, nonadjacent jumps and short verses.
For sufficiently spaced adjacent lines it requests a bounded animation of
at most 0.16 seconds (or 22% of source-time spacing). The default 2x rate
still leaves time for the requested animation in the synthetic model.
Automatic focus/status transitions match the decision and avoid additional
0.30-second overlap on fast passages. Manual drag disables auto-follow until
return-to-live, preserving existing user control. No timers or delay offsets.

### Baseline/result available without a physical iPhone

| Synthetic scenario | Previous policy | New policy |
|---|---:|---:|
| Three scrolls 180ms apart | 2 overlapping requested 400ms animations | 0 requested animations |
| Single ordinary adjacent transition | 400ms requested | <=160ms requested |
| Seek, jump over several lines | 400ms animation | immediate |
| Duplicate automatic target | can repeat request | suppressed |

Physical before/after FPS, CPU/GPU and user-perceived stutter remain
**unmeasured**; do not claim release acceptance from pure XCTest alone.

## Instrumentation correction

A paused/background interval must not be counted as an animation hitch.
`timelineSuspended()` resets only the tick-to-tick interval baseline on
pause, inactive/critical visual suspension, track replacement and view exit.
Counters are retained until an explicit `reset()`. Device capture remains
required; the long-frame metric observes SwiftUI tick gaps, not GPU hitch time.
