# Gnarly: real neural stems — continuation checkpoint

Status: IN_PROGRESS. User requires zero paid services; use genuine open-source
separation, never label the approximate InstantStemMasker as real isolation.
Baseline: build 49, commit 1302a054e96de04fbf715e728d809459fe09c557.
Working branch: feature/gnarly-build50-real-stems-final. Never restart from main.

Current decision: on-device Core ML HTDemucs, with Accelerate STFT/iSTFT,
streaming overlap-add, independently mixed real stems. No cloud audio upload,
paid API, subscription, or external account required. Weights and port licenses
must accompany the app. Do not promise perfect separation for every recording.

Reference sources inspected (MIT; preserve notices for copied code):
- tsyrenov1987/demucs-coreml-ios @ 8bc00d620eada4c75dc668c37704feb675be2f59
  /workspace/reference-demucs-coreml: converter, DSP, golden tests, GOTCHAS.
- kristerssaulitis/stemsplitter @ a5c813e681d5c3e4a1a1543dffc6ea651f566d79
  /workspace/reference-stemsplitter: streaming pipeline, model reader, mixer.
- Meta Demucs and weights: MIT, official model sources.
REA was inspected (morluto/rea); it is a reverse-engineering toolkit, not a stem
model or a source of premium-service access. No need for REA for the open models.

Existing app: InstantStemAudioUnit is an approximation on original audio;
StemSplitterEngine's offline Wiener and backend/stems_dev.py are not connected
to the current live UI. Replace actual mixer path, not just labels.
Keep the same live AVAudioEngine and original player as transport/clock, attach
four prepared players and gains before common speed/pitch/EQ/reverb. Preserve
seek/pause/end/interruption, karaoke, original source identity and Share/export.
Preserve source UI/branding/assets/search/download behavior from build 49.

Work still required at this checkpoint:
1. Audit conversion model shapes and reference pipeline compatibility.
2. Convert and validate real HTDemucs Core ML model against PyTorch. Bundle it
   in deliverable IPA; do not rely on private URLs or embedded GitHub tokens.
3. Streaming on-device separator with bounded memory, cancellation and durable
   per-source/model-version cache. Read fp16 strides correctly; CPU+GPU on real
   device, CPU-only for simulator, never use ANE blindly (see GOTCHAS).
4. Real independent stem playback and matching offline/Story mixes.
5. Clear progress/ready/error UI, sliders only for actual prepared tracks.
6. Meaningful model/DSP, independent mute/solo, seek, export tests. Full existing
   CI gates and package identity check (Gnarly/build>=50/iPhoneOS/arm64).
7. Deliver correct IPA and concrete device-testing limitations. No paid resources.

Environment: Linux, no Xcode/Swift. Use GitHub Actions macOS for model and iOS
validation. Python model env: /workspace/gnarly-model-env (3.11). uv cache and
Python install dirs must be writable under /workspace. FFmpeg is installed.
No GPU/API credentials configured; not needed for selected on-device route.
There is no applicable AGENTS.md. Do not delegate unless user authorizes it.

Task resumption: inspect latest branch files/commits, PR and workflow runs first;
do not overwrite newer work. Continue incomplete implementation and validation.
If status is COMPLETE and the correct IPA is already delivered, do not duplicate.
Update this checkpoint at each milestone, commit/push it before ending a turn.

## Integration milestone — 2026-10-20

User confirmed iPhone-only, to distribute to colleagues; zero paid services.
The neural feature needs iOS 18+, while the rest of the app keeps its iOS 17 target.

Implemented but not delivery-validated at this milestone:
- Real Core ML model reader with strided fp16 outputs, Accelerate DSP and golden tests.
- NeuralStemWorker: cancellable serial streaming decode, normalization, chunked
  inference, overlap-add, four Float32 WAVs, content-hash/model-version cache.
- Four real players and independent scalar gains in the existing engine;
  common host-time start, pause/seek/EOF handling, original source at all 100%.
- Actual stem assets frozen into Audio/Performance/Story export.
- Prepare/progress/cancel UI; sliders enabled only when actual stems are ready.
- Five integration/format/delivery tests, plus five ported DSP golden tests.

Local conversion succeeded: torch 2.12.0+cpu, demucs 4.1.0, coremltools 9.0;
surgery max error 0.0. Core ML package ~101 MiB. Runtime parity is still mandatory.
Pinned source: adefo/HTDemucs (actual full repo/revision and source SHA256 values
are in scripts/neural-stems/model-manifest.json).

Model build is entirely CI-managed, WITHOUT a private release download or any
API secret in the IPA. A local `gh release create` asset-upload attempt failed
with credentials error; no usable model release exists. Do not retry that path.
Reusable neural-stems.yml converts on Ubuntu, uploads a workflow artifact,
then runs the complete Swift/Core ML versus PyTorch gate on macOS. ios.yml now
requires this reusable job and embeds its verified compiled-model artifact.

Prior CI troubleshooting:
- 39477030656: obsolete attempt to download missing private release.
- 39478978490: rejected a cross-host converted-weight byte hash. Fixed by pinning
  original safetensors/config SHA256, per-build conversion integrity, plus the
  independent full-sample numerical parity gate (MIL packing order can vary).
- 39480090168: model conversion passed; Swift package manifest rejected .v15
  under tools-version 5.9. Fixed using .macOS("15.0") in commit dd990b3.

NEXT: inspect newest CI run after dd990b3, resolve actual Swift/runtime issues;
run the app's full PR gates, fix any playback/resampling tests, verify the final
IPA includes the model and Gnarly identity, then deliver build 50 or later.
Do not deliver build 49 again and do not claim physical iPhone testing.
Scheduled continuation exists (one-time, two hours after initial scheduling);
pause it when work is complete to prevent duplication. Record fresh CI/PR state.

## Precision investigation — 2026-10-20 19:30 UTC

Head 0471689 compiled the iOS app successfully (run 39482676935). All five
Swift DSP golden tests passed on macOS. Full neural parity failed on the fp16
conversion: per-source NRMSE drums 0.0519, bass 0.0660, other 0.0303, vocals
0.1700 on the seeded white-noise tensor. Correlations were 0.9873–0.9996.
The gate remains strict (correlation >0.98 AND NRMSE <0.05 for every source).
CPU+GPU and CPU-only produced identical results on the hosted Mac runner.
A separate Linux reconstruction check matched PyTorch iSTFT to <1e-6.

Current change preserves float32 graph precision (model identifier/cache key
htdemucs-v4-core-fp32-v1) instead of relaxing validation. Converter now emits
raw frequency/time golden tensors. Swift gate compares the entire STFT and,
on failure, predicts from exact PyTorch inputs to diagnose raw branch drift.
Next inspect CI for this change, fix any precision/conversion issues, then
run the full IPA gate. No IPA has been delivered for build 50 yet.

## Float32 parity passed — 2026-10-20 20:05 UTC

Run 39483627322 PASSED full neural parity on an Apple Silicon Mac:
- drums NRMSE 0.0000393, bass 0.0000712, other 0.0000272, vocals 0.0001459;
- all correlations >0.999999996; whole STFT maximum error 7.45e-8;
- all five Swift DSP tests passed, unchanged strict per-source acceptance.
The fp32 graph fixes the conversion drift; do not revert to the all-fp16 graph.
Compiled model artifact Gnarly-Neural-Model is ~100 MB compressed (12292786856).
App compile and Karaoke Clean checks also passed for 80e57c5.

The matching IPA run 39483633729 failed because its macOS arm64 parity job
could not acquire a hosted runner after retries (capacity annotations, no
test failure). Switch delivery/parity to macos-15, already working for app
compile/karaoke, and eliminate duplicate automatic standalone model jobs;
the full IPA workflow still requires the complete reusable model gate.

Code review caught the original recording's gain after the common sum. Move
it before the sum using a separate stereo resampler, so muting the original
cannot mute the four stems. Offline exports now use that exact shared graph
and original-source gate; the independent isolation/mute test covers it.
Added selected-source-time stem export regression. Next full IPA CI and
artifact inspection, followed by final PR/checkpoint and automation pause.
