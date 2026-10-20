# Gnarly build 51 — offline artwork and queue continuation

Status: IN_PROGRESS. Continue this branch, not main:
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
