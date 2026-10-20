# Gnarly build 51 — offline artwork and queue continuation

Status: COMPLETE. Verified build 51 is available; do not duplicate the work.
Delivery details follow at the end. Implementation branch, not main:
`fix/gnarly-build51-offline-artwork-queue-final`.
Baseline: verified build 50, app d4b39824, checkpoint head 056136d.
The real local HTDemucs integration, omnibox, branding and all other features
must remain intact. User reported missing offline covers in internal/system
players and next-track unavailability despite wanting to advance the queue.

Implemented, awaiting CI:
- Persist validated artwork bytes beside downloaded audio; optional sidecars
  preserve the existing cache index/session format and follow audio eviction.
- Backfill from SDWebImage disk/memory cache or HTTPS; prepare cover separately
  from playback and publish current-track-only updates when saved. Audio starts
  immediately; explicit offline saves wait for the cover attempt to finish.
- Both internal player covers use PlayerArtworkImage with local file support
  and source-identity/cancellation guards. The system artwork loader uses the
  same saved URL. Share's existing local-file loader remains supported.
- Wait for audio cache readiness before restoring the last session.
- Persist the app's Up Next order in UserDefaults; test queues stay isolated.
- One PlaybackCoordinator.nextSelection drives next-button availability and
  dispatch in both players; keep forward-history behavior then resume queue.
- Next-button selection doesn't reorder the remaining queue as a manual
  discovery skip; queue entries are consumed only after playback succeeds.
- Keep remote controls connected while any audio is loaded, including pause
  and screen disappearance. Bump Info.plist/project version to 51.

Meaningful new tests cover persistent local cover loading for internal/system
players and Share, invalid-cover protection/deletion, restored queue advance
and failure-safe consumption, forward→queue transitions, and MPRemote next
availability with a queued song and no forward history.

Next: commit/push, open a PR against build-50 branch, inspect compile, Karaoke
and the full IPA workflow; fix any Swift/API/test failures. Keep all neural,
Metal, Share and unfiltered tests required. Download and inspect the final IPA
for Gnarly/build51/iPhoneOS/arm64/model inclusion before delivery. No physical
iPhone is available. Build-50 continuation automation was paused on completion;
do not reactivate it for this separate fix. Do not merge main or deploy backend.

PR 115 is open against build 50. First CI head 3566c07 compiled successfully;
Karaoke Clean also passed. Full IPA run 39501827900 is/was in progress. Code
review added compatibility for flat legacy audio paths: sidecars always belong
to separate per-ID directories, and deletion never removes the shared cache
root. A regression covers distinct covers and deleting only one legacy track.
Next inspect the latest run after this compatibility fix (not the old head).

Also update system command availability directly after confirmed playback,
queue arrival/removal and session restoration: SwiftUI onChange can be deferred
while the screen is locked. Keep queue capability independent from temporary
export blocking; AudioEngineManager observes its own isExporting transition to
disable/re-enable remote commands without depending on a visible screen.

All consumers of the player's resolved local URL now use PlayerArtworkImage:
main/blurred/vinyl artwork, the TrackIdentityPill thumbnail, and static/marquee
cover backgrounds. Brand logo/lockup and assets remain intact. Share already
supports local files. Validate the latest head, not intermediate canceled runs.

## Verified delivery — 2026-10-20

Tested application source: 24d8053dbc6b686d87b83fad7fb00f5b0412a145.
All checks passed: iOS Build, Karaoke Clean, Share Card, numerical Core ML
parity, complete iOS neural runtime, 14 Metal/Share regressions and the full
661-test suite (zero failures, 1 pre-existing skip). All six new offline cover,
legacy cache, restored queue and MPRemote next regression tests passed.

CI: https://github.com/miscrapha-DELTA-IA/NightcoreLab/actions/runs/39505507168
Artifact ZIP with unsigned IPA:
https://github.com/miscrapha-DELTA-IA/NightcoreLab/actions/runs/39505507168/artifacts/12305005566
PR: https://github.com/miscrapha-DELTA-IA/NightcoreLab/pull/115

Downloaded and inspected the actual IPA:
- /workspace/gnarly-build51-delivery/Gnarly-build51.ipa
- SHA256 b46334d49b59aaa9d7fbfe7e26924cf198358de76e00b551e75e134b8f49b3fa
- 111,079,536 bytes; archive CRC verified.
- Gnarly / build 51 / com.nightcorelab.app / iPhoneOS arm64.
- Model htdemucs-v4-core-fp32-v1 included (209,746,277 bytes), MIT notices
  and passing parity evidence included. App iOS 17+, neural stems iOS 18+.

Old downloads whose cover bytes were never saved require an online visit to
fetch the image; existing SDWebImage cached covers are also migrated. The
button remains unavailable when neither queue nor forward history has a
candidate. No physical iPhone test was performed. No main merge/backend deploy
or new continuation automation was performed. The final checkpoint-only commit
does not change the tested app source.
