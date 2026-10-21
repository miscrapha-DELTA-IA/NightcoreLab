# Build55 — hear a short preview before a long stem job

Status: COMPLETE — build55 code, full validation and inspected unsigned IPA delivered. Final delivery below supersedes historical working notes. User says a4m53song shows35min for stems; **clarified that35min is ONLY the on-screen estimate, not measured elapsed time**. Native sideload on XR; no paid services, PC/server dependency for runtime, or downgrade of branding/omnibox/real stems.

Branch fix/gnarly-build55-stem-preview-acceleration-final based on8d9ffa9 (build54 validated app708060c). User's clarification changed immediate scope: fix misleading ETA and provide real quality preview. Initial GPU/float16 exploration was read-only; no new conversion/model/compute-unit policy has been adopted. Current model remains pinned fp32 staged HTDemucs v2 and existing memory guards. Do not claim35min is actual measured runtime or promise an XR speedup.

Implemented so far:
- StemProgressEstimator ignores the cold first segment, requires2warm measurements, uses median of last5 and excludes memory-recovery stalls; reports approximate range. Preview never extrapolates a single segment to whole song.
- Worker request .full/.preview(at:). Preview seeks near playhead, decodes at most7.8s/343980samples, runs actual neural model once, writes original WAV+4real stems+actual drums/bass/other accompaniment. Separate cache key/manifest.previewStart; old full caches remain compatible. Keep only3preview folders; never prune full stems.
- AudioEngineManager same draining/cancellation/analysis resource lease, request-aware injected operation. Preview gets separate observable asset and never replaces full transport/files or enables whole-song stems. UI secondary Generate8secondpreview and QuickLook compare Original/Voice/Accompaniment; original playback pauses when opening audio preview. Verify QuickLook SwiftUI API compiles/preview works on actual XR.
- Optimize float32 tensor IO: resolve dataPointer once and bulk-copy contiguous rows, preserving padded strides and all source waveforms. No quality/precision/segment changes.
- Bumped55. Tests for cold/warm/recovery ETA, seek+onecontext preview limit; complete neural worker test now checks real preview, original, accompaniment sum, isolated preview/full caches. Lifetime injection signature updated4parameters.

Still required: inspect compile issues, full CI and model quality/memory gates, inspect actual55 IPA, ready PR and deliver with physical XR limitation. No local Swift/Xcode/device on Linux; use existing GHmacOS workflows. /workspace/verify-gnarly-ipa.py supports>=54 with26loads and6repeat-memory checks (55same model). Existing Recovery50/52/53 paused;54creatednone. User had authorized conditional recovery scheduling before context exhaustion; if recovery created for55, PAUSE after completion.

Build54 fallback source708060ccd5b4c537323b5f3611a375c3474295ca, PR118readyunmerged. IPA /workspace/gnarly-build54-delivery/Gnarly-build54.ipa; SHA287de3db915b98bdaf61ec04b18c348f0c771d55279f9c57087b49ec139725cb. Fullworkflow39556119600 artifact12326762825;677tests1skip0fail. No main merge/backend deploy/public release authorized by this task.

## Final delivery — complete

Validated app source **32745ccd30ee74dbbf9f7b30a7f0ea9444cbcc7f**. PR119 ready for review, basefix54branch; no main merge, server deploy or public release. No new GPU/float16 model or compute-unit policy was shipped: only read-only research, followed by user clarification that35min was an ETA.

- Full IPA workflow **39564202756**, app job **119103865200** succeeded: **681tests,1existing external-fixture skip,0failures**,19targeted neural/runtime/DSP tests,14targeted Metal checks, Release iPhoneOS success. Complete real-worker preview test and seek/one-context-limit test passed both targeted and full runs. Covers original audio, accompaniment=sum of actual instruments, preview cache reuse and separation from full-song cache.
- iOS compilation workflow **39564202679**, job119102434809 passed. Only2workflows trigger for these paths; no standalone Share/Karaoke workflows were run, fullsuite includes their tests.
- Model parity job **119102893526** passed CPU/GPU stock PyTorch noise/music quality, fullSTFT,26loads/segment,6CPUrepeat-inferences and unchanged400MiBphysical/800MiBresident limits.
- Bundled CPU report: physicalpeak **349964864bytes (~334MiB)**,RSSpeak **693174272bytes (~661MiB)**; post-inference physical samples **[74581824,74811200,74549120,74991552,90130368,89769920]**, within32MiBpost-warmupgrowthgate. These are MAC validation-host figures, NOT XR measurements or evidence of a promised speedup. First inference7.823s on Mac, not a phone timing claim.

[Artifact ZIP containing unsigned IPA](https://github.com/miscrapha-DELTA-IA/NightcoreLab/actions/runs/39564202756/artifacts/12329759736)

Artifact **12329759736**,NightcoreLab-App,111599378bytesZIP. Local **/workspace/gnarly-build55-delivery/Gnarly-build55.ipa**,111952429bytes.
SHA256 **d8c728ccc5a897eddd529864852ba9257161064d55b6bb0ed1a9f64c12c3a9c0**.
Verification JSON alongside IPA; /workspace/verify-gnarly-ipa.py <ipa> 55 PASSED. Gnarly55/com.nightcorelab.app/iPhoneOS/arm64/min17;26completecompiledmodels/29instructions/210928216modelbytes;MITqualityandmemoryevidence; no symlinks, legacy monolith, signature or profile. Real stems still requireiOS18.

Usage: seek near a representative part of the song; choose Gerar prévia de8segundos. This means AUDIO DURATION, not a promise of8seconds processing. Once ready, compare Original/Sóvoz/Semvoz through QuickLook. Preview pauses the main player when opened, remains separate from complete-track stem controls, and uses the same real model. Its short-context normalization need not be bit-identical to full-song normalization. Full processing remains a separate explicit action. ETA waits for warm measurements instead of extrapolating cold preparation.

Local runtime has no Swift/Xcode/physical XR. Preview playback, generation latency and full-track time on XR still need user validation; cannot promise perfect source separation for every song. Current task created NO recovery automation; previous50/52/53 remain previously paused. Documentation completion commit uses[skip ci], leaving validated app source unchanged.
