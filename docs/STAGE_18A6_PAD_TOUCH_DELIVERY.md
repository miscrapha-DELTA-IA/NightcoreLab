# Stage 18A.6 — Direct Pad Touch Delivery (PR #58)

## Base and evidence
Stacked on `stage-18a5-device-latency-evidence`, head `97f2f5e3`, PR #57.
All user recordings used `BluetoothA2DPOutput`. There are **three**
unique sessions, with a duplicated warm report (do not double-count).

| Scenario | Hits | UIKit→handler p50/p95 | touch→audio command p50/p95 | warm command p50/p95 | node.play p50/p95 |
| --- | ---: | --- | --- | --- | --- |
| Music + pads | 63 | 106.68 / 148.27 ms | 119.02 / 161.68 ms | 12.90 / 24.31 ms | 11.58 / 22.04 ms |
| Warm deck | 107 | 81.96 / 115.97 ms | 98.26 / 130.30 ms | 14.99 / 24.48 ms | 14.45 / 23.24 ms |
| Cold start | 93 | 74.13 / 124.58 ms | 89.01 / 148.54 ms | 17.49 / 24.39 ms | 15.68 / 22.33 ms |

`node.stop` p95 was 2.09–3.50ms, `scheduleBuffer` p95
0.10ms, and there were no rejected pad hits. Two cold engine
starts took 77.06ms and 511.58ms. These are software-only
timings: no acoustic or visual end-to-end measurements.

## Hypothesis 1 — Scroll view interception of touches
The UIKit `UIControl(.touchDown)` pads previously lived inside the
SwiftUI `ScrollView`. Apple's documented default for UIKit
`UIScrollView.delaysContentTouches` is true: the scroll view may
delay touch delivery to decide whether the user intends to scroll.
Reference: https://developer.apple.com/documentation/uikit/uiscrollview/delayscontenttouches

The measured pre-handler medians of 74–107ms are consistent with
that explanation, but **do not prove it is the exclusive cause**.
A deliberately narrow change moves the playable `LazyVGrid` into
a fixed sibling above the `ScrollView`. Settings, sample picker,
recording and diagnostics remain scrollable. Pad targets are 90pt
high instead of 102pt to preserve some space on smaller phones.
No UIKit hierarchy introspection or new Gesture recognizer.

## Hypothesis 2 — cold start on first hit
The app stops its AVAudioEngine after inactivity. One measured cold
`engine.start()` was 511.58ms. `beginPerformanceMode()` prewarms the
EXISTING shared engine as the sheet opens, preventing idle stop while
the instrument is visible. `endPerformanceMode()` restores normal
idle stop and stops pad voices without pausing a playing song.
Source replacement rewarms only while the deck is visible.

This moves the startup delay to opening the instrument. It has
a temporary CPU/battery cost while Performance Mode stays open.
Unexpected iOS interruptions can still stop the engine.

## Deliberately unchanged
No new engine, no polyphony/allocator or `node.stop` changes,
no time/lyrics clock changes, no sample or event schema changes,
and no modification to the offline export, karaoke, Story, or DSP.

## iPhone before/after protocol
- Repeat the same route/device/music, haptics off, with 60+ hits,
  fast single strikes and 2–4 fingers.
- Compare the **UIKit→handler** p50/p95 from PR #57 vs #58.
- Compare `node.play` p95 and rejected hits to detect regressions.
- Confirm that in a warm open sheet almost every hit is marked
  warm; confirm cold engine startup when the app legitimately
  restarts or after dismissing Performance Mode.
- Independently repeat using iPhone speaker rather than Bluetooth,
  which adds output latency not measured by software timings.
- Check compact-screen access to controls below the pad deck,
  source clip, recording/export, visual feedback and karaoke.
- **No measured post-change improvement yet.** Do not label this
  fix a resolved fingerdrumming issue before physical A/B.
