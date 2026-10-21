# Build53 — stems actually fit the XR

Status: COMPLETE — code, automated validation and inspected IPA delivered. Physical XR confirmation remains pending. User confirms build52 performance/UI now good, but stem guard rejects at4% for memory. Must reduce model RAM, not just lower safety check. Preserve all build52 behavior/UI.

Branch fix/gnarly-build53-staged-stems-final from6d49f9a. New model ID htdemucs-v4-staged-fp32-global-attention-v1. HTDemucs unchanged7.8s fullcontext/fp32. Split20CoreML models/25pipeline operations; copy owned outputs and release model at each stage; release skip tensors at final use. Move GLOBAL dense attention to Swift Accelerate cblas using64query rows at a time, all keys/values retained, stable full-domain softmax; no shortened context/quantization. PyTorch prototype maxdiff1.6018748e-7 vsstock before CoreML.

Local env /workspace/gnarly-model-env python3.11/torch2.12/coremltools9. Source weights pinnedHF SHA sameoriginal /workspace/gnarly-hf-cache/models--adefossez--HTDemucs/snapshots/cbc8a9b1a87023b7fd74e7b3412e6321c0eab003/955717e8.safetensors. HF_HOME=/workspace/gnarly-hf-cache HF_HUB_DISABLE_XET=1 required (defaultcache readonly). Local modeldir /workspace/gnarly-staged-model; log /workspace/gnarly-staged-conversion.log. Converter convert_staged.py +staged_core.py, fullsource/weights hashes andfullaudio parity mandatory. Initial issuesstatsstackscalar CT unsupportedfixedwithcatflatten; stageinputsnoncontiguousfixedargs.contiguous(). Local --resume-conversion reuses completed prototype stages; CI alwaysfreshsourcehash.

Runtime StagedDemucsPipeline.swift, BlockedAttention.swift, DemucsCoreMLModel.swift wrapper. Per-stage memoryheadroom256MiB rather thanwhole-model1GiB. Decoder20models sameHTDemucs sources. Need CoreML runtime validation & peak target<=400MiB standalone CPU (repeatsegmenttoensurememorydoesnotaccumulate). May need reducefurther basedactualmacCI; do notrelaxqualitygate. Need addmeaningfulattention/ownedcopytests &updatePackage/CI/modelverifier/IPAverifier. Workflowneuralupdatedforstaged20models. Newartifact folder Neur alStems/htdemucs_staged (no space). Do not accidentallybundlemonolith. NeedopenPRtofullCIonceprototypepasses. No currentCI/PR yet.

No physicalXR/XcodeonLinux. UseGHmacos15. Oldbuild52artifact12312130518 source1e97def model900MiB+1GiBadmission fails onXR. CurrenttasknotcompleteuntilcorrectIPA53deliveredaftertests. No paidservices, no PC/serverneeded; no mainmerge/backenddeploy. Oldautomationsbuild50/build52 paused. Userauthorizes recovery scheduling if contextneeded; no newautomationyet.

Prototype manual run39544631557: source276f847, convertpassed20models, SwiftDSPpipelinecompiled; SPMAttentiontestexpressiontypechecktoo complexline28, fixedexplicitweightedloop. New syntheticmusicalfixtureaddedforfullfour-sourcequalitygate; CPUrepeatpreventsretainedstageallocationgrowth. StillneedmacPeak/qualitymeasurebeforeclaimimprovement.

Probe2 run39545108182 / e8315dd: ALL numerical gates (noise+musical) excellent, but CPUpeak897MiB failed400MiB limit. Stageprofiles335MiB throughtransformer, climbsdecode1→418,decode2→612,decode3→826. Identifiedspectral3x3rewriteim2colworkspace: lastfullconvneeds~300MBscratch. Fixv2splitdecoder spectral/time; frequencysubtiles32rowswith2rowhalo (rewritecontext1+stride4/kernel8transposeoverlap1), edgeinput34/inner36. AssertpinnedmodelglobalnormFalse beforetiling; timecontextfull7.8s unchanged. PyTorchfullstaged+decoderTiles maxerrorstill1.6018748e-7. NewmodelID htdemucs-v4-staged-fp32-tiled-v2,29pipelineinstructions26compiledmodels. Initialencodeadmission384MiB (profiling335totalpeak),genericothers256MiB,subtile96MiB. NeednextmacCPUmemorygate<=400,do notrelaxjusttopass. Resourceworking_memfieldoptionalforencode0override.

Probe3 run39546258097 source31b6af0: tiled spectraldecoder fixedspectrumworkspace, numericalnoise+musicexcellent. FirstCPUinferRSS438MiB, firstkernelphysicalpeak285MiB; after3inferencesCPUtotalRSS714.36MiB but **kernelphysicalpeak374.565MiB** (392759872bytes),GPUphysical310.78MiB. JSONdownload/tmp/gnarly53-probe-v2.zip artifact12321738176. Arbitrary400RSSgatefailed: RSS includescleanmmap/modelweights. CorrectiOSbudgetmetric iskernelledgerphys_footprint (dirty+compressed), perAppleWWDC21/10180 andWWDC22/10106. Qualificationnowrequires **kernelphysical<=400MiB AND reports/enforcesRSS<=800MiB**; qualitythresholdsunchanged. Not hidingRSS: JSONcontainsboth. Entryencode0physicalpeak228MiB incl30MiBbaseline, sosafeheadroom256MiB (no1GiB upfrontguard). Othernormalstages256,subtiles96. NewfullCIwillrecheckthese metricsbeforeappbuild. No physicalXRavailable; cannotclaimactualdevicepeak375.

Full delivery qualification: source5567301, PR117 basefix52branch, fullIPA run39546914459 andiOSBuild39546914434. Only2workflows trigger duepathfilters; Share/Karaokeuntouched,fullsuitecoversall. Modelmemorygates calibratedtochargedkernelphysical<=400MiB ANDtransparentRSS<=800MiB, not400RSSassumption. Initialencodebudgetnow256MiB based228MiBwholekernelpeak(including30baseline), allnormal256/subtile96; no384or1GiBcheck. iOSstandalonegate18neural/DSPtests,fulltestsexpected671; SPM7DSP/attention. FinalIPAverifier /workspace/verify-gnarly-ipa.py nowvalidates53 modelIDv2,29instructions22coreml+2spectraldecoder+5attention, fullcontext343980,source4qualitynoise/music, kernelphysical<=400RSS<=800, initial256. Needensure26compiledpartdirs. No oldmonolithallowed.
Recoveryautomation6ad846c392c08191ad4bb6f336889804 ENABLED once+90min from~2026-10-21T05:00Z; pauseaftercompletion. Prior50/52automationspaused. Do notpushcosmeticswhilefullCIruns; locallyupdatecheckpointandfinal[skip ci]afterdeliveryverified. Newappsource is5567301; repo cleanapartthislocaldocupdate.


## Final delivery — complete

Validated source: **5567301dcc5e80bd4196d84152b6dbb82f544679**. PR117 is ready for review; no merge/main or backend deployment.

- Full IPA run **39546914459**, build job119048155904: **671 tests,1 existing skip,0 failures**,18neural/DSP regressions,14targeted Metal checks,Release iPhoneOS build success.
- iOS compilation run39546914434: success. Share/Karaoke standalone workflows did not trigger because those paths were unchanged; fullsuite includes their tests.
- Model gate job119047443209: CPU/GPU passed stock PyTorch per-source parity for noise and synthetic music, repeat inference, full STFT parity;7SPMDSP/attention tests passed.
- Actual bundled CPU report: kernelphysicalpeak **391039552 bytes (~373MiB)**,RSSpeak **762232832 bytes (~727MiB)** after repeated inferences, within400MiBphysical/800MiBresident limits. These are standalone macOS validation-host figures, NOT measured XR RAM. Do not compare oldRSS910MiB directly with newkernelphysical373MiB.

[Artifact ZIP containing unsigned IPA](https://github.com/miscrapha-DELTA-IA/NightcoreLab/actions/runs/39546914459/artifacts/12323396400)

Artifact **12323396400** NightcoreLab-App,111544105 bytes ZIP.
Local **/workspace/gnarly-build53-delivery/Gnarly-build53.ipa**,111895930 bytes.
SHA256 **22a64802c75b0511277c3c5266685ec93ed433834b1d26a23fc24f7cec8d035b**.
Verification JSON next to IPA; /workspace/verify-gnarly-ipa.py <ipa> 53 passed.
ZIP CRC valid; Gnarly53/com.nightcorelab.app/iPhoneOS/arm64/min17;26compiled parts,29instructions,210928216 bytes model,MIT,noise/music parity andCPUfootprint evidence included. No model symlinks or old monolithic model. Real separation requires iOS18 as before.

Final memory admission is256MiB per regular stage and96MiB per spectral tile, with memory-warning cancellation. The previous fixed1GiB guard is gone. Original full7.8s context, fp32weights and global attention are preserved. Only stem preparation and its temporary volatile cover-cache purge changed; build52 UI/startup/search/queue/offline covers remain.

Recovery automation **6ad846c392c08191ad4bb6f336889804 is PAUSED** after completion; earlier50/52automations remain paused. This completion documentation commit uses[skip ci]. The IPA app source above remains unchanged. No physical XR is attached: user confirmation that generation now completes on the XR is still necessary. Do not claim physical-device certification or guaranteed speed.
