# Stage 18A.4 — PR #56 | Latency findings and minimal correction

Baseline: `stage-18a3-fingerdrum-latency-profiling` at
`e01e01eb1668734cffa7f1d82e9f098d7f725ddb` (PR #55).
This is a stacked draft PR. No merge to `main`.

## Findings supported by source and CI

1. PR #55 has successful iOS Debug, full XCTest/Release/IPA, and backend
   workflows. Those checks do not measure audible pad onset.
2. The only user-observed real-device outcome is **functional audio, but
   insufficiently fluid/instant feel for fingerdrumming**. There is no
   published device latency report in PR #55 or its discussion.
3. Real input already uses `UIControl(.touchDown)`, not a release-triggered
   SwiftUI `Button`. Samples are predecoded. The app has one live
   `AVAudioEngine`, and we must keep it.
4. The PR #55 probe incorrectly recorded `touchToCommandMS` and
   `commandMS` **after** `scheduleIdleStop()` on pads-only strikes.
   That code cancels/creates an idle-stop `Task` after the
   `AVAudioPlayerNode.play()` submission. Consequently the purported
   software command latency could include unrelated main-actor bookkeeping.
   The measurement boundary, not the audio engine, required correction.

## Smallest safe correction

`AudioEngineManager.triggerPad` now timestamps the completion of the
`PadAudioRuntime.trigger()` call (after `node.play` returns, before
`scheduleIdleStop()`). Both displayed elapsed values use that endpoint.
The idle stop policy, actual trigger, voice allocation, graph, sample buffers,
karaoke and export remain byte-for-byte behaviorally unchanged.
`PadLatencyProbe.elapsedMilliseconds(from:to:)` has a pure validation
contract, and tests assert that post-command bookkeeping is excluded.

This is a **measurement-correctness fix**, **not yet an audible-latency
improvement**. No p50/p95 improvements are claimed.

## Decision tree for measured iPhone data

| Case | Evidence required | Next minimal change | Status |
|---|---|---|---|
| A — software command fast, onset slow | Warm `touchToCommand` p50/p95 is low relative to independent touch-to-acoustic timing, on the **same route** | Examine AVAudioSession IO buffer duration, output route and player scheduling; change only the diagnosed part | **Unclassified — no acoustic measurements** |
| B — software command slow | Warm `touchToCommand` p95 high relative to target; `stop`, `schedule`, `play`, `engine.start` breakdown identifies contributor | Fix only dominant measured operation; assess idle-stop task scheduling or node stop/restart first *if measured* | **Unclassified — no measured p50/p95** |
| C — audio fast, UX feels late | Independent acoustic-onset low, but touch-to-photon/held-pad feedback lag high | Isolate pad highlight to a UIKit visual state and avoid heavy SwiftUI invalidations or animations *if measured* | **Unclassified — no visual measurements** |

Do not invent absolute `low`/`high` millisecond thresholds. Establish
a target based on the user's actual device/route and a reference input
device or recording. Multiple causes can coexist. The probe reports
**command submission**, not hardware-render or Bluetooth onset.

## Required evidence to choose the actual user-facing fix

Fill only after an instrumented session on an iPhone:

- iPhone model / iOS version / speaker or wired/Bluetooth route:
- Capture: at least 40 **warm** fast pads, including 2–4 simultaneous
  touches. `touchDispatch` p50/p95:
- `touchToCommand` warm p50/p95, max:
- `nodeStop` / `nodeSchedule` / `nodePlay` p50/p95:
- Cold first strike, `engine.start` p50/p95 and count:
- Independent acoustic onset p50/p95 measured with a consistent method:
- Independent visual feedback timing or recording:
- Playback playing vs paused/idle; impressions with capture disabled/enabled:

**Invalidation:** Discard PR #55's `touchToCommand` and `commandMS`
figures when attempting to infer `scheduleBuffer/play` overhead.
They may include idle-stop bookkeeping. Collect a fresh trace on PR #56.

## Regression gates

- Debug build and full XCTest (including `PadLatencyProbeTests`).
- Release and unsigned IPA; backend regression.
- Manual comparison in the same conditions before claiming improved
  fingerdrumming feel.
- No new AVAudioEngine, MIDI engine, audio tap, clock, network reporting,
  or file IO on touch.
