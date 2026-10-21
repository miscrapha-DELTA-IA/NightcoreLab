# Build55 — hear a short preview before a long stem job

Status: IN PROGRESS. User says a4m53song shows35min for stems; **clarified that35min is ONLY the on-screen estimate, not measured elapsed time**. Native sideload on XR; no paid services, PC/server dependency for runtime, or downgrade of branding/omnibox/real stems.

Branch fix/gnarly-build55-stem-preview-acceleration-final based on8d9ffa9 (build54 validated app708060c). User's clarification changed immediate scope: fix misleading ETA and provide real quality preview. Initial GPU/float16 exploration was read-only; no new conversion/model/compute-unit policy has been adopted. Current model remains pinned fp32 staged HTDemucs v2 and existing memory guards. Do not claim35min is actual measured runtime or promise an XR speedup.

Implemented so far:
- StemProgressEstimator ignores the cold first segment, requires2warm measurements, uses median of last5 and excludes memory-recovery stalls; reports approximate range. Preview never extrapolates a single segment to whole song.
- Worker request .full/.preview(at:). Preview seeks near playhead, decodes at most7.8s/343980samples, runs actual neural model once, writes original WAV+4real stems+actual drums/bass/other accompaniment. Separate cache key/manifest.previewStart; old full caches remain compatible. Keep only3preview folders; never prune full stems.
- AudioEngineManager same draining/cancellation/analysis resource lease, request-aware injected operation. Preview gets separate observable asset and never replaces full transport/files or enables whole-song stems. UI secondary Generate8secondpreview and QuickLook compare Original/Voice/Accompaniment; original playback pauses when opening audio preview. Verify QuickLook SwiftUI API compiles/preview works on actual XR.
- Optimize float32 tensor IO: resolve dataPointer once and bulk-copy contiguous rows, preserving padded strides and all source waveforms. No quality/precision/segment changes.
- Bumped55. Tests for cold/warm/recovery ETA, seek+onecontext preview limit; complete neural worker test now checks real preview, original, accompaniment sum, isolated preview/full caches. Lifetime injection signature updated4parameters.

Still required: inspect compile issues, full CI and model quality/memory gates, inspect actual55 IPA, ready PR and deliver with physical XR limitation. No local Swift/Xcode/device on Linux; use existing GHmacOS workflows. /workspace/verify-gnarly-ipa.py supports>=54 with26loads and6repeat-memory checks (55same model). Existing Recovery50/52/53 paused;54creatednone. User had authorized conditional recovery scheduling before context exhaustion; if recovery created for55, PAUSE after completion.

Build54 fallback source708060ccd5b4c537323b5f3611a375c3474295ca, PR118readyunmerged. IPA /workspace/gnarly-build54-delivery/Gnarly-build54.ipa; SHA287de3db915b98bdaf61ec04b18c348f0c771d55279f9c57087b49ec139725cb. Fullworkflow39556119600 artifact12326762825;677tests1skip0fail. No main merge/backend deploy/public release authorized by this task.
