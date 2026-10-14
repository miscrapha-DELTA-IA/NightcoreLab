# Stage 18A.5 — Device Latency Evidence Handoff

## Status
- **Base:** PR #56 / `stage-18a4-latency-findings-minimal-fix`,
  `08638966684b2ffed73cf71d657efc03c88a5240`.
- PR #56 iOS Debug, complete XCTest/Release/IPA and backend checks: green.
- **No actual iPhone software p50/p95 or acoustic-onset timing values** were
  provided in the discussion or in PR #56 comments.
- This PR is **evidence capture/communication**, NOT the proposed
  "Pad Voice Architecture" optimization. Do not modify the engine, voice
  allocation, synth, output buffer, or karaoke/render pipeline without
  a measured diagnosis.

## New UI for iPhone tests
Inside `Performance → Diagnóstico de latência`:
1. Select `Engine quente`, `Primeiro toque frio`, or `Música + pads`.
2. Press `Iniciar medição`. The route type, actual engine running
   state, music status and haptic setting are snapshotted **at start**.
3. Perform the test; end capture. Up to six completed session summaries
   are retained in memory until the sheet disappears.
4. `Copiar` or `Compartilhar relatório` produces the identical,
   human-readable p50/p95 text across collected scenarios. Paste it into
   the NightcoreLab diagnostic conversation. `Limpar resultados`
   clears prior results.

The report explicitly says that software timings are NOT acoustic onset
or touch-to-photon timings. Its input is numeric counters and constant
system `AVAudioSession.Port.rawValue` types only; **no audio-route
`portName`** (may identify a user's Bluetooth headphones),
sample IDs, track paths/titles, lyrics, waveform, or user identifiers.
No network or logging during pad touch. Formatting happens only on Finish,
Copy or Share; capture is bounded at 1,024 touches.

## Reproducible protocol
Use the **same iPhone and output route** for the first comparison.
Separate speaker/headphone and Bluetooth measurements.
- **Warm:** start a song to ensure that the live AVAudioEngine is running,
  measure 40–60 rapid taps, two-finger hats and 3–4 finger rolls.
- **Cold:** stop playback and wait until the engine has stopped (default
  idle-stop schedule is ~10 s). Capture before the first touch; confirm
  `Engine running at capture start: no`, and `cold: 1` or more.
- **With music:** keep playback active; confirm `Music playing: yes`.
  Do not assume Karaoke or visualization renders behind a covered sheet.
  Verify separately with Instruments if a real full-visual contention
  scenario is needed.
- Repeat with opt-in latency capture **disabled** to check whether
  instrumentation affects perceived musical performance.
- If available, use high-frame-rate recording or audio-loopback to observe
  actual physical touch→sound and touch→pad highlight. Software markers
  cannot establish either one.

## Classify after receipt of device evidence
A: touch→command fast but physical sound late → buffer/session/output
route or audio scheduling; do not infer from software metrics alone.
B: touch→command slow → determine whether engine.start, node.stop,
scheduleBuffer or node.play dominates; one measured fix at a time.
C: acoustic sound fast but pad highlight appears late → measure actual
touch-to-photon and SwiftUI state/render before UI changes.

**Voice architecture is gated.** No Stage 18A.5 voice pool replacement
or changes to `node.stop()` until case B is specifically supported.

## Validation
- iOS Debug compilation
- XCTest includes `PadLatencyEvidenceReportTests` and existing probe
  percentile/bounds tests
- Release + unsigned IPA
- Backend regression
- iPhone physical protocol; only then diagnose and implement the narrow fix
