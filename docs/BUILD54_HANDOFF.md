# Build54 — resource ownership while separating stems

Status: IN PROGRESS. User confirms build53 now separates real stems on the XR, but liquid background animation freezes/stutters, separation is slow, and simultaneous playback/navigation can exhaust memory until restarting. User clarified native sideload, NOT LiveContainer; background means the animated UI, NOT iOS background execution.

Branch: fix/gnarly-build54-stem-resources-final, based on build53 34c9565 (validated app source5567301). Preserve all branding/omnibox/queue/offline/karaoke/real fp32 model behavior. No paid APIs/server/PC needed for separation. Linux workspace has no Swift/Xcode/physical XR. Use existing GitHub macOS full CI, inspect final IPA and deliver54.

Changes in progress:
- Tile spectral decoder reuses one compiled model per shape, grouping independent edge/interior tiles. Still ONLY one model resident at a time, exact same inputs/halo/full context/fp32. 42 model loads per segment become26; speed on XR must be measured, do not claim a percentage speedup.
- Whole utility-job autorelease pool and allocator pressure relief BEFORE completion continuation resumes; segment-boundary relief. Memory errors retry only the uncommitted segment twice after cache cleanup, preserving prior overlap-add output. Permanent shortages still fail cleanly with retry message, no forced app restart.
- Keep isPreparingStems true during cancellation until actual worker finishes; no new neural job/export may race a draining model. Remove unused visual FFT tap during inference, restore afterward. Shared optional analysis scheduler suspends/cancels and waits for actual cleanup before model starts.
- Main liquid shader intentionally froze during neuralWorkActive in build53. New budget keeps30fps flow at half linear resolution and no secondary detail; ordinary XR shader uses0.75 scale. Frozen/share exports remain full resolution. Optional decorative/FFT analysis stays suspended. Root energy budget now propagates neural work to other UI trees.
- Build number54. Meaningful new regressions for retries, resource drain, tile coverage and scheduler barriers. Full neural gate now6repeat inferences,26loads/segment and bounded post-warm-up growth32MiB; existing quality/physical400MiB/RSS800MiB limits unchanged.

Still required: inspect diff/compile errors, run full CI via draft PR basefix53branch, fix failures without weakening gates, inspect54 IPA (verifier currently supports<=53; extend54), check repeated memory report, mark PR ready and deliverunsignedIPA with physical XR limitation. Do not merge main or deploy backend.

Build53 delivered IPA /workspace/gnarly-build53-delivery/Gnarly-build53.ipa. SHA22a64802c75b0511277c3c5266685ec93ed433834b1d26a23fc24f7cec8d035b. New distribution-plan artifact from previous turn is separate and does NOT authorize public release. Recovery automations50/52/53 previously paused. If long recovery scheduling becomes necessary, user previously authorized scheduling completion before context exhaustion; create bounded recovery then PAUSE after delivery.
