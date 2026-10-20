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
