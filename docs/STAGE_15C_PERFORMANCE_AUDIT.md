# Stage 15C — initial audit and validation ledger

Baseline: `2c2ce27` (main, merged 14B/15A). Read
`RUNTIME_STABILIZATION_STAGE10C.md` before edits. The additional energy document
was not available in Library; the requirements transcribed in the task are used.

## Evidence before edits

| Surface | Continuous work / policy | Decision |
| --- | --- | --- |
| AudioEngineManager | pause pauses the node only; the running graph is not stopped | Cancellable delayed stop; capture source time, invalidate callbacks and reschedule on resume |
| TurbulentMarbleView | Timeline capped at caller's 30/60 FPS, paused by scene and Reduce Motion; frozen Story path bypasses timeline | Central budget only for live schedule; shader and frozen path untouched |
| KaraokeLyricsView | Only active word line uses animation Timeline; no explicit interval | Explicit frame budget; preserve timestamp resolver and word progress |
| ContentView | Vinyl animation has no explicit interval; progress scrubber already 15 Hz | Limit vinyl; retain scrubber |
| PlayerBackground | Marquee repeatForever; scene handling restarts on active but does not explicitly stop on background | Central decoration admission and cancellable SwiftUI task |
| CreativeReactiveAccent | Visible-only cancellable task, 12 Hz playing / 450 ms paused; separate power observer | Central policy; keep existing equations and cadence |
| AudioFeatureEngine | Actor, utility analysis, cancellation and persistent MusicIntelligence cache; own LPM read | Accept explicit value budget for live analysis; export entry points unchanged |
| StoryVideoExporter | One in-flight frame, writer actor, MainActor rasterization, existing render/encode signposts and 15 ms yields | No change without device data |
| TelemetryManager | Existing opt-in singleton; possible configurable endpoint | Do not reuse for MetricKit; separate app-owned local subscriber |

Existing caches already cover source identity, analysis, compiled composition and
prepared typography. Static background blur caching, new envelope interpolation,
export yields and DSP changes are deferred until profiling justifies them.

## Measurement boundary

This executor is Linux with no Xcode, simulator, Swift compiler or iPhone.
Source inspection establishes scheduling behavior, not CPU/GPU/energy savings.
No before/after consumption numbers are available. Explicit 60/30/15 FPS caps
are policy limits, not measured rendered FPS (60 can reduce ProMotion cadence).
No cache/per-frame algorithm optimization is justified by this audit.

## Required validation

CI: XcodeGen, full XCTest, Release device build and unsigned IPA. Existing
runtime/material/typography parity and audio quality tests remain gates.
Device: compare baseline and branch on identical device/OS/track/settings,
5-minute warmup and 15-minute playback + 30-second pause + resume; repeat 3 times.
Record Instruments CPU, allocations/RSS, Energy Log, Metal System Trace FPS,
thermal state, Low Power state, route and background audio continuity. Include
30-minute sessions, seek during suspension, remote play, interruption and route
changes. Capture equal-timestamp Story images and listen for resume glitches.
MetricKit daily aggregates supplement this experiment, not an instantaneous
before/after profiler. GPU time and animation hitch ratio are not Metal FPS;
true Metal FPS requires Instruments without replacing/instrumenting the renderer.

## Risks

Audio stop/resume resets the live DSP tail after the idle grace period; sample
position and settings must survive, but bit-identical reverb tails across a long
pause cannot be claimed. Background suspension can delay a timer. Daily metrics
may be absent in simulator. Device parity and energy validation remain pending.


## Implemented scope

- `EnergyBudget.swift`: scene environment, one power/thermal observer pair,
  value policy (nominal 60, fair/LPM 30, serious 15, critical/background paused).
  `allowsExport` is exposed for admission by future consumers; it does not
  interrupt or alter the existing export pipeline.
- `AudioEngineManager.swift`: configurable 10-second idle grace, cancellable
  deadline, source position and DSP controls retained, stale callback guard,
  transport signposts for Instruments. Replay at EOF still restarts from zero.
- `ContentView.swift`, `KaraokeLyricsView.swift`, `TurbulentMarbleView.swift`,
  `PlayerBackground.swift`, `NowPlayingScreen.swift`: live frame scheduling.
- `Creative/CreativeReactiveAccent.swift`, `Creative/AudioFeatureEngine.swift`:
  shared admission policy for automatic analysis and live reactions. Existing
  cached export entry points and legacy response API remain unchanged.
- `NightcoreLabApp.swift`, `LocalPerformanceMetrics.swift`: app-owned subscriber,
  serial utility IO, allowlisted numbers, 30 records / 64 KiB, atomic protected
  file in Application Support/LocalPerformance, excluded from backup. Missing
  metrics remain nil. No raw payload or device metadata retained.
- `EnergyBudgetTests.swift`, `PerformanceRegressionTests.swift`: policy matrix,
  denied-analysis IO, actual AVAudioEngine pause/resume/seek/EOF/replacement/
  interruption and bounded persistent numeric metric records.

MetricKit uses `scrollHitchTimeRatio` (iOS 14+) for iOS 17 compatibility.
The first CI compile revealed that general `hitchTimeRatio` requires iOS 26;
that API was replaced, without raising the deployment target. Scroll hitch
ratio is explicitly not a Metal FPS measurement.

Existing `RuntimeStabilizationTests`, material/typography parity suites and
`AudioQualityTests` supply the rendering/DSP regression gates; they are not
replaced by policy-only assertions. Physical-device parity remains unverified.
