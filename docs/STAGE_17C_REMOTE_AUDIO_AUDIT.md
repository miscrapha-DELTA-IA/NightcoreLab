# Stage 17C — iOS remote transport & audio-route hardening

Baseline: `stage-17b-search-persistence-robustness` (all three CI workflows
passed at `e03dbfd9`). Stack order: #48 → #49 → #50 → Stage 17C.
**No merge was performed.**

## Existing architecture, confirmed by repository inspection

- `AudioEngineManager` already owns a single `AVAudioEngine`,
  `AVAudioPlayerNode`, an output clock and `MPNowPlayingInfoCenter`.
  It already supports local file playback, speed, seeking, idle engine
  suspension, output route latency refresh, and `AVAudioSession` playback.
  `Info.plist` already declares `UIBackgroundModes = audio`.
- `PlaybackCoordinator` (17A) owns intent vs confirmed playback; queue,
  navigation, SavedPlaybackSession and DownloadManager remain the existing
  authoritative stores. Previously, only play/pause/toggle remote commands
  were registered, while next, previous and absolute seek were disabled.
- `EnginePlaybackClock.lyricTime` accounts for actual iOS
  `AVAudioSession.outputLatency` and source-time conversion through
  `AVAudioPlayerNode.playerTime`. Route changes refresh that cached latency.
  **No arbitrary fixed 150ms compensator is appropriate here.**
- `AudioFeatureEngine` derives a source-time timeline from cached
  MusicIntelligence and is independent from the live audio graph. The
  `AudioVisualFrameBus` actor already has a bounded latest-wins queue and
  beat sequence, deliberately not a real-time audio tap.
- Story export and preview resolve `CompositionRuntime` by source and
  export timestamps. Existing parity tests remain part of full XCTest.

## Stage 17C implementation

- One remote-command registration per AudioEngineManager lifetime:
  `play`, `pause`, `toggle`, `next`, `previous`, and absolute seek.
  `MPChangePlaybackPositionCommandEvent.positionTime` is source seconds.
  iOS callback handlers cross to the MainActor before accessing transport.
- The engine holds a **weak** link to a SwiftUI-owned `RemotePlaybackRelay`.
  Its actions invoke the **same** ContentView/PlaybackCoordinator queue
  selection, navigation and seek functions used by the screen.
- Next is enabled only when a forward navigation entry or queued track
  exists. Previous restarts current track if there is no previous entry.
  Playback commands disable during export. Seeking is available only with
  loaded audio and valid duration. No duplicate player or queue.
- The old play/pause/toggle engine-only fallback remains for contexts where
  a SwiftUI relay has not been attached. On detach, queue navigation and
  absolute seeking are disabled.
- `AVAudioSession` interruption begin pauses; end tries to reactivate and
  resume **only** if playback had been active, iOS signaled
  `shouldResume`, the same source is still loaded and no manual
  pause/track replacement/route removal invalidated intent.
- Unplugged audio output pauses and does not immediately route playback to
  built-in speaker. All route changes refresh the existing lyric output
  latency. NowPlaying continues using the existing source clock/speed.
- Tests cover remote-relay lifecycle and resume policy. No new package,
  Spotify streaming code, token storage or privacy manifest changes.

## Latency / performance: measured vs unmeasured

**No iPhone latency measurement was available for this PR.**
Spotifast `src/vis.rs` uses a lagged window behind its PCM tap.
NightcoreLab is NOT architecturally the same: its lyrics clock already
compensates iOS output latency and the creative feature timeline is indexed
by source time. Subtracting another arbitrary lag would double compensate
in some routes and could break preview/export parity.

Do NOT install a second AVAudioEngine or an always-on tap yet. The next
measurement gate is a device matrix: built-in speakers, wired headphones,
Bluetooth; speed 0.8/1.0/1.25/1.5; seeking; interruptions; background;
Low Power; Reduce Motion. Log source clock, route/output latency and the
visual-frame source timestamps (not raw audio/user data), and compare
observed audiovisual alignment. If the residual delay is consistent,
apply a **deterministic, opt-in live-only policy** with a default of zero,
preserving the offline Story renderer's timestamp contract.

## Release gates / risks

- Python offline unittest; XcodeGen + SPM; full Swift XCTest; Debug
  + Release and unsigned IPA; karaoke regression; warning delta from Stage
  17B. Device-based behavior, latency, battery and Bluetooth remain manual
  gates; CI simulator cannot assert real hardware route switching.
- MPRemoteCommandCenter sends actions asynchronously to MainActor. The
  command callback acknowledges enqueueing; true playback success/failure is
  reconciled via the PlaybackCoordinator generation token before committing
  queue/history state.
- The existing TrackID-less local audio import supports play/pause/seek
  without pretending it has a YouTube track ID.
