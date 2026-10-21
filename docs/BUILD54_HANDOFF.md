# Build54 — resource ownership while separating stems

Status: COMPLETE — build54 code, full validation and inspected unsigned IPA delivered. Final delivery section below supersedes historical working notes. Physical XR timing and concurrent playback/navigation confirmation remains pending. User confirms build53 now separates real stems on the XR, but liquid background animation freezes/stutters, separation is slow, and simultaneous playback/navigation can exhaust memory until restarting. User clarified native sideload, NOT LiveContainer; background means the animated UI, NOT iOS background execution.

Branch: fix/gnarly-build54-stem-resources-final, based on build53 34c9565 (validated app source5567301). Preserve all branding/omnibox/queue/offline/karaoke/real fp32 model behavior. No paid APIs/server/PC needed for separation. Linux workspace has no Swift/Xcode/physical XR. Use existing GitHub macOS full CI, inspect final IPA and deliver54.

Changes in progress:
- Tile spectral decoder reuses one compiled model per shape, grouping independent edge/interior tiles. Still ONLY one model resident at a time, exact same inputs/halo/full context/fp32. 42 model loads per segment become26; speed on XR must be measured, do not claim a percentage speedup.
- Whole utility-job autorelease pool and allocator pressure relief BEFORE completion continuation resumes; segment-boundary relief. Memory errors retry only the uncommitted segment twice after cache cleanup, preserving prior overlap-add output. Permanent shortages still fail cleanly with retry message, no forced app restart.
- Keep isPreparingStems true during cancellation until actual worker finishes; no new neural job/export may race a draining model. Remove unused visual FFT tap during inference, restore afterward. Shared optional analysis scheduler suspends/cancels and waits for actual cleanup before model starts.
- Main liquid shader intentionally froze during neuralWorkActive in build53. New budget keeps30fps flow at half linear resolution and no secondary detail; ordinary XR shader uses0.75 scale. Frozen/share exports remain full resolution. Optional decorative/FFT analysis stays suspended. Root energy budget now propagates neural work to other UI trees.
- Build number54. Meaningful new regressions for retries, resource drain, tile coverage and scheduler barriers. Full neural gate now6repeat inferences,26loads/segment and bounded post-warm-up growth32MiB; existing quality/physical400MiB/RSS800MiB limits unchanged.

Still required: inspect diff/compile errors, run full CI via draft PR basefix53branch, fix failures without weakening gates, inspect54 IPA (verifier currently supports<=53; extend54), check repeated memory report, mark PR ready and deliverunsignedIPA with physical XR limitation. Do not merge main or deploy backend.

Progress 06:34Z: PR118 draft https://github.com/miscrapha-DELTA-IA/NightcoreLab/pull/118 . Initial source0cdb75b compiled iOS successfully, Share suite passed, model parity CPU/GPU passed with26loads/segment. Initial CPU physicalpeak351078912bytes (~335MiB), RSS662847488 (~632MiB), firstinfer7.308s ON MAC VALIDATION HOST ONLY. Six post-inference footprints [72304256,89736768,90310272,90326720,90687104,90457728], stable after warmup. Initial model diagnostics12325812145 downloaded/tmp/gnarly54-initial-model.zip. Karaoke first runner failed checkout/action.yml before source checkout; rerun subsequently started, no app failure identified.

Final app source708060ccd5b4c537323b5f3611a375c3474295ca adds drawingGroup BEFORE scaleEffect to enforce low-resolution rasterization and a measured-per-segment ETA, plus committed-output progress (no backwards jumps from overlap). Full CI FINAL source run39556119600; iOS39556119531; Share39556119483; Karaoke39556119507. Old source full39555447993/Karaoke39555447892 cancellation requested to free runners. Do not use old IPA if it appears. /workspace/verify-gnarly-ipa.py already extended54:26loads/segment,6CPUrepeats,boundedgrowth32MiB, existingquality/400physical/800RSS unchanged. Current local checkpoint change uncommitted; leave until final delivery [skip ci].

Build53 delivered IPA /workspace/gnarly-build53-delivery/Gnarly-build53.ipa. SHA22a64802c75b0511277c3c5266685ec93ed433834b1d26a23fc24f7cec8d035b. New distribution-plan artifact from previous turn is separate and does NOT authorize public release. Recovery automations50/52/53 previously paused. If long recovery scheduling becomes necessary, user previously authorized scheduling completion before context exhaustion; create bounded recovery then PAUSE after delivery.

## Final delivery — complete

Validated app source **708060ccd5b4c537323b5f3611a375c3474295ca**. PR118 ready for review, basefix53branch; no main merge, public release or backend deployment.

- Full IPA workflow **39556119600**, build job **119078275444** succeeded: **677 tests,1 existing external-fixture skip,0 failures**,18neural runtime/DSP regressions,14targeted Metal checks; Release iPhoneOS build passed. New cancellation lifetime, scheduler drain and recovery tests passed.
- Final iOS compilation **39556119531** passed. Share **39556119483** passed8tests; Karaoke **39556119507** passed38tests. Initial superseded full/Karaoke runs were cancelled; they are not delivery evidence.
- Final neural job **119077416647** passed CPU/GPU per-source stock PyTorch parity for noise+music, full STFT parity,11SPMDSP/recovery tests,26loads/segment and6CPUrepeat inferences.
- Bundled CPU report: kernelphysicalpeak **348916224 bytes (~333MiB)**,RSSpeak **685981696 (~654MiB)**; unchanged400MiBphysical/800MiBresident limits. Post-inference footprints **[89933696,89720704,89638784,89622400,89573248,89556928]** stabilize/decrease after warmup. These are standalone MAC HOST results, NOT measured XR RAM or timing. Do not claim a percentage XR speedup.

[Artifact ZIP containing unsigned IPA](https://github.com/miscrapha-DELTA-IA/NightcoreLab/actions/runs/39556119600/artifacts/12326762825)

Artifact **12326762825** NightcoreLab-App,111564436bytes ZIP. Local **/workspace/gnarly-build54-delivery/Gnarly-build54.ipa**,111916233bytes.
SHA256 **287de3db915b98bdaf61ec04b18c348f0c771d55279f9c57087b49ec139725cb**.
Verification JSON alongside IPA; /workspace/verify-gnarly-ipa.py <ipa> 54 PASSED. Gnarly54/com.nightcorelab.app/iPhoneOS/arm64/min17;26compiled models,29pipeline instructions,210928216modelbytes,MIT,CPU/GPUquality+repeat-memory evidence. No model symlinks, legacy monolith, signatures or embedded profiles. Real stems still require iOS18.

Runtime: output progress follows committed overlap-add samples; ETA uses actual segment time after first segment. Temporary memory pressure retries only uncommitted segment, at most2recoveries; persistent shortage stops cleanly after cleanup. Cancellation keeps busy state until worker drains; UI/export cannot race a draining model. Optional analysis suspends/drains; visual meter tap pauses. Liquid shader stays moving at30fps CAP (not measured guarantee), half resolution/no secondary detail during stems; ordinary constrained devices0.75scale. DrawingGroup precedes magnification. Frozen/share exports remain full resolution. Offline export waits until separation ends; playback remains available.

No new recovery automation was created; previous50/52/53 remain as previously paused. Only final documentation commit after delivery uses[skip ci], without changing the validated app source. No physical XR attached: user must confirm playback/navigation during separation, time, and retry without app restart.
