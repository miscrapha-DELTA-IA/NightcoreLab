# Stage 66 — Selfie video recorder beta

## Scope
- The player and karaoke views expose a small red recording dot inside a theme-colored circular rim (accessibility identifier: selfie.openRecorder) in the top-right control group, between Share and Karaoke.
- One tap presents an in-app front-camera recorder. The user explicitly taps Record/Stop, then chooses Save to Photos or Share.
- Recording uses an AVCaptureSession with video and microphone movie output (.mov) on a serial queue. AudioEngineManager, the single AVAudioEngine, song transport, clock, visual presets, and Story export are unchanged.
- When Karaoke mic scoring/Vocal FX already owns the live mic input, those taps are released before the new capture to avoid two owners of that input.
- NSCameraUsageDescription and microphone/Add to Photos messages document opt-in capture. Permissions are requested on entry only.
- Temporary local movie files are removed on dismiss/discard. Saving to Photos is explicit.

## Known beta boundaries
- Camera + voice only. The song audio is not digitally mixed into the movie. Speaker audio may be picked up by the microphone.
- Audio hardware routing can differ on specific iPhone and headphones. Test on physical devices before sending the invitation.
- The fullscreen player is replaced with the camera while recording; music transport should continue, but lyric overlays are not in the captured video.
- A denied permission results in a clear message instead of fake recording.
- Simulator lacks a real selfie camera. Automated tests cover initialization and local file naming, not camera A/V fidelity.

## Device acceptance
1. Update to the Stage 66 IPA; load a track and confirm the small red circle appears next to Share and Karaoke.
2. Open camera; grant camera/microphone; check correct portrait orientation and selfie mirroring.
3. Record ~10 seconds of singing, stop and save to Photos. Verify visible video with voice audio.
4. Confirm music playback continuity with speaker and headsets before/during/after recording.
5. Test denying permissions, discarding an unsaved take and backgrounding during capture.
6. Do not update the invite IPA link until the Stage 66 workflow succeeds and provides a downloadable artifact.

## Delivery
- Branch: stage-66-selfie-video-final
- Base: stage-65-gnarly-creative-universe-final
- Badge / CFBundleVersion: v66 / 66.
