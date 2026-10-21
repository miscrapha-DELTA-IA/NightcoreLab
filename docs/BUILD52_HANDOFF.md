# Build 52 — XR performance and stem load crash

Status: COMPLETE — implementation, automated validation and IPA inspection finished. Physical XR confirmation remains pending. Do not rebuild or deliver build 51 again.

User device: iPhone XR (3GB RAM). Slow/black startup; increasing stuttering with actions; stem crash ~4% (progress covers MLModel loading and the first inference). No physical device/crash log available. Investigate memory, do not claim jetsam confirmed.

Baseline: ef3a205 (build 51) on fix/gnarly-build51-offline-artwork-queue-final, PR115. Preserve advanced Gnarly UI, omnibox, four REAL neural stems, saved cover/queue fixes. New branch fix/gnarly-build52-xr-performance-final.

Plan: measure CoreML CPU/GPU peak in separate macOS processes and preserve strict audio parity; choose memory-safe compute for XR; prevent low-memory kills; remove eager all-library cover migration, coalesce/decode off main with bounded cache; stop unnecessary dormant audio processing and constrain older-device live shader cadence. Test, build, inspect and deliver correct IPA52.

No paid APIs/server/PC for stems. Linux workspace lacks Xcode/device. GH macos-15 CI performs actual CoreML + iOSSimulator tests. User asked persistent completion; continue if compacted. No merge/main or backend changes.


Current app source: 065319c. Draft PR116, base build51 fix branch. Full IPA run39514607862, simulator build39514607863, Share39514607908, Karaoke39514607869, all running. Do not push cosmetic/doc changes while tests run (cancels full IPA pipeline).

Implemented:
- Artwork actor coalesces reads/bitmap decoding, 12MB/6-entry NSCache, off-main ImageIO downsample768, no SD PNG re-encoding. Startup no all-library cover fetch; lazy migration on select/save. Memory warnings clear volatile cover cache. Offline sidecars unchanged.
- StateObject lifetime wraps @Observable AudioEngineManager to prevent expensive engine constructors on view-value recreation. Temp cleanup utility/deferred, stale owned files only (>24h).
- Eight neural audio nodes created/connected only when stems prepared; detached after stopping engine on source replacement. Original player and offline/live mix preserved.
- XR/<=4GB uses full-fp32 CoreML CPUOnly (no ANE/no GPU graph loading). Tensor IO per-complex-plane avoids full spectral input/output copies (~55MB).
- Before real-device model load require >=1GiB process headroom via os_proc_available_memory, cancellation on memory warning, checks at boundaries and after load, utility queue. No fake EQ stems.
- Constrained device live decorations30fps/detail0.25; stem work pauses decorative shader/optional live analysis, root discovery task cancels. Export rendering unchanged.
- Offline-library refresh cancels superseded scans.

Model itself unchanged (pinned HTDemucs fp32): first baseline probe run39513626304 (8940332) passed GPU/CPU per-source. Latest updated DSP gate job118943808088: CPU peak911MiB, loaded473MiB, GPU885MiB; all four NRMSE<=.000304, corr>=.999999984, full STFTmax7.45e-8. Both processes on macOS; not comparable to physical A12 / actual iOS jetsam. CPU host regression limit1GiB.

Tests added: coalesced bitmap identity/read count + clear-on-pressure; lazy stem node allocation/detach; padded complex-plane read/write; XR CPU selection; resource admission/decorations; worker memory warning abort before model load and cleanup. Linux no Swift. Await macCI; inspect failures if any.

Final deliverable: download NightcoreLab-App artifact from full run via GitHub connector; extract IPA to /workspace/gnarly-build52-delivery/Gnarly-build52.ipa; run /workspace/verify-gnarly-ipa.py <ipa> 52 (now also requires CPU parity+memory JSON). Share durable artifact link, confirm unsigned route and physical XR not tested, no claim measured-device startup/crash guaranteed. Mark PR ready after all4checks pass, update checkpoint COMPLETE withartifact/SHA and commit docs [skip ci].


First full run39514607862 failed 3 assertions across2tests (667 total, 1skip). No stem/DSP/image/visual failure. Stale-temp cleanup test expected synchronous deletion of *new* files, so updated to await shared off-main helper with old-owned/new-owned/old-unowned fixture coverage. DownloadIndependence test waited an arbitrary100ms for pending queue publication; now awaits its actual Published matching set with5s timeout. Full build job timeout raised30→45min: initial whole test phase alone finished27m54s, before Release build. Other3checks passed on065319c. New full CI required after this fix; do not deliver failed run.

Final retry source: 1e97def. Runs39518412603 IPA (job118956741861),39518412514 compile,39518412606 Share,39518412521 Karaoke. Watch PTY31891 writes /tmp/gnarly52-final-watch.log. Neural gate job118956149544 succeeded; final tests pending. Recovery automation6ad800c92c748191b0477800d62f683a enabled once2026-10-21T01:31:13Z; MUST pause after successful delivery to avoid duplicate work. Prior build50automation remains disabled.


## Final verified delivery

All four checks PASSED on source **1e97defb88a1a13619aa191093684fe2bb970331**:
- Full IPA run39518412603, job118956741861:16 neural/DSP regressions,14 targeted Metal regressions, **667 full-suite tests,1 existing skip,0 failures**; Release iPhoneOS build succeeded.
- iOSBuild39518412514, Share39518412606, Karaoke39518412521: success.
- Both CPU/GPU per-source CoreML parity passed, correlation>=.999999984, NRMSE<=.000304. CPU process peak954482688 bytes (~910MiB), below1GiB host regression gate. These are macOS validation numbers, not an XR RAM measurement.

Artifact **12312130518**, NightcoreLab-App:
https://github.com/miscrapha-DELTA-IA/NightcoreLab/actions/runs/39518412603/artifacts/12312130518

Local **/workspace/gnarly-build52-delivery/Gnarly-build52.ipa**; SHA256 **7a2955e38be87e68266f602729cb1cd5e76e6cd9cf477311fe6973202435d0fe**;111094381 bytes. Neighbor .verification.json records checks. ZIP wrapper110796248 bytes. ZIP CRC valid; Gnarly52/com.nightcorelab.app/iPhoneOS/arm64/min17; pinned210MB model+MIT+both parity reports included. Model separation requires iOS18.

This is the unsigned IPA route used previously. No physical XR is connected; do not claim the device crash/black screen has been empirically eliminated. CPUOnly on <=4GB avoids GPU graph specialization, preserves full-fp32 model quality, and may separate more slowly. User should test on the XR. Memory admission fails with a readable error if its remaining process budget is insufficient, rather than starting a risky allocation. No paid service, main merge or backend deploy.

Recovery automation6ad800c92c748191b0477800d62f683a is PAUSED after completion. PR116 is ready for review. This documentation-only completion commit uses [skip ci]; the IPA source SHA above is unchanged.
