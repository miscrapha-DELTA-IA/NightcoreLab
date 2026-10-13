# Stage 18A.3 — Fingerdrumming Latency Audit

## Scope and truthfulness
The user tested the pads on an iPhone: they play audio but do not yet
feel instant or fluid enough for fingerdrumming. **No measured latency
number was supplied**. Do not present perceived delay as an x-ms fact.

Implementation baseline:
`stage-18a2-source-clip-pad` @ `3ba8155876375b5a64fbf048e20c7964523ef2c7`.
Stack this PR on #54 without merging open draft PRs.

## Code audit and hypotheses
Real input path:
`UIControl.touchDown` → SwiftUI-hosted coordinator closure →
`AudioEngineManager.triggerPad` → `PadAudioRuntime.trigger` →
`AVAudioPlayerNode.stop/scheduleBuffer/play` → existing mixer + limiter.

**Already true:**
- The pads do NOT dispatch through a SwiftUI `Button`; a UIKit
  `UIControl` touch-down target is used, `isExclusiveTouch=false`, and
  every pad has its own control. Do not introduce another UI layer.
- All seven original PCM samples (and an optional CLIP sample) are
  preloaded. There is no disk IO or PCM decode on touch.
- Each trigger calls `AVAudioPlayerNode.stop()`, even for a free voice.
- Triggering a pad when the shared engine is stopped calls `engine.start()`.
  Idle-stop scheduling and cancellation also run on the main actor.
- Velocity currently uses a fixed default value, not touch pressure. Do not
  describe it as pressure-sensitive or infer dynamic velocity from iPhone
  hardware that doesn't expose force.
- A `@State heldPads` visual update formerly preceded the sound command.
  For the instrumented revision the sound command is called first; this
  preserves tap intent but slightly changes UI scheduling order.

These are candidate contributors, not measured root causes.

## New opt-in measurement
Performance Mode → **Diagnóstico de latência** → Iniciar medição.
Strike ~40 pads; include simultaneous two-finger taps, repeated hats,
warm engine with a song playing, and an idle/cold first hit.
End session to display local **p50 / p95** metrics:
- UIKit event timestamp → handler entry
- Touch event → command submission completed
- Synchronous command duration, warm versus cold
- Time spent starting the shared AVAudioEngine
- Time in AVAudioPlayerNode stop, scheduleBuffer and play
- Accepted / rejected pad commands.

All values are milliseconds **inside the app**. They do NOT measure when
the first sample reaches the physical speaker (hardware buffer, DAC),
Bluetooth path, perceived sound/visual parity, or the SwiftUI frame at
which the pad changes appearance. Use a loopback/audio interface or
independent high-frame-rate recording with a reference transient for
actual touch-to-sound / touch-to-photon tests. No invented benchmarks.

No music title, URL, lyrics, sample ID, voice, audio data or exact event
timestamp is stored. Numeric data stays in bounded main-actor memory,
at most 1,024 hits. No per-touch print, disk write, analytics, network
request, extra audio engine or output tap. Closing Performance Mode
cancels the capture. This is a development diagnostic; remove or gate
it after characterizing actual bottlenecks.

## A/B test protocol (same device and audio route)
1. In the prior green release (PR #54), reproduce 40 fast kicks/hats and
   2- to 4-finger overlap, then capture audio/visual from the device.
2. In this diagnostic branch, repeat the same sequence with capture
   disabled, then enabled. Compare by ear and Instruments Time Profiler.
3. Run with source playback active versus pads-only; keep speed 1× first.
4. Compare wired/iPhone speaker with Bluetooth separately. Bluetooth
   latency is highly route-dependent.
5. Measure the first strike after the idle stop and the following ten,
   logging cold/warm counts separately.
6. Investigate stop/schedule overhead ONLY if its p95 is a significant
   contributor; if internal command latency is low but audible onset is
   still slow, examine actual audio buffer/scheduling/output-route delays.
7. Run EnergyBudget/Low Power and thermal cases later, but do not
   degrade music playback to improve UI FPS.

## Acceptance gate
Full XcodeGen, iOS Debug, all XCTest including PadLatencyProbeTests,
Release and unsigned IPA; then physical iPhone analysis. Do not claim
fingerdrumming is repaired from green CI or submillisecond function calls.
No changes to Story export, karaoke clock, existing PCM samples, kits,
polyphony policy or recording schema.
