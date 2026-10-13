# Stage 18A.2 — Source Clip Pad / Sample Picker

**Branch:** `stage-18a2-source-clip-pad` stacked on approved green
`stage-18a-performance-pad-engine` SHA `d419a269aa8325ebe3b823e17de296b835ccd179`.
No earlier draft PR is merged by this increment.

## Product scope
A single extra `CLIP` pad is optionally created from a bounded **0.25–5 second**
range of the current locally loaded music track. The Performance Mode stays
the only surface; the Player and Karaoke do not gain extra panels or buttons.
This is a **one-shot** assignment, not loop transport or stem separation.

## Architecture and protections
- `PerformanceSourceClip` stores only a source-time range; **no URL/audio
  data** in Codable `PerformanceTimeline`. The new optional field retains
  compatibility with older schema v1 event JSON through decodeIfPresent.
- Picker confirms rights to use/share a segment before allowing assignment.
  This is a user attestation, not a DRM bypass nor proof of licensing.
- The range is read/decoded in a detached task; bounded stereo float PCM at
  48 kHz is returned as Sendable arrays. `PadAudioRuntime.installSourceClip`
  then prepares its buffer **before** touch-down. A tap triggers the same
  12-voice node pool and shared limiter, never a disk read.
- Extractor uses bounded linear resampling and short fades for the initial
  MVP. The source is not duplicated indefinitely, persisted as a sample
  file, or uploaded to a backend. Quality and latency need real-device tests.
- `AudioEngineManager.playbackSourceRevision` guards asynchronous assignment
  against mid-prepare source changes; loading a new track clears the clip.
- Changing the clip clears earlier recorded events rather than silently
  remapping an old performance to new waveform content. Recording snapshots
  the selected clip metadata. Export passes the original current source URL
  only to the existing offline renderer, which re-extracts the frozen slice
  and mixes its events in chunks alongside original pads. Standard audio
  exports remain unchanged.

## Explicit deferrals
- Continuous loops require start/stop transport events and deterministic
  offline automation. Do not ship a loop toggle that cannot be recorded or
  represented in a Story.
- Preview/video/Story of custom pad events, waveform UI, quantization,
  beat alignment, stems and mic remain outside this bounded PR.
- License rights cannot be inferred from imported music. Confirm permission
  before redistributing audio clips, even if generated locally.

## Validation
- Synthetic mono/stereo 44.1 kHz WAV clip extraction, 48 kHz prepared
  buffer, long/invalid selection rejection.
- v1 backward-compatible JSON, no serialized source URL.
- Offline stem at a known source time and 44.1 kHz output rate.
- Source revision invalidation on track replacement and stale async result.
- XcodeGen/Debug, full XCTest+Release+IPA, Karaoke Clean Mode regression,
  backend regression; real-device polyphonic latency and CPU/power follow-up.
