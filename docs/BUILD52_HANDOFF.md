# Build 52 — XR performance and stem load crash

Status: IN PROGRESS. Do not deliver build 51 again.

User device: iPhone XR (3GB RAM). Slow/black startup; increasing stuttering with actions; stem crash ~4% = MLModel load. No physical device/crash log available. Investigate memory, do not claim jetsam confirmed.

Baseline: ef3a205 (build 51) on fix/gnarly-build51-offline-artwork-queue-final, PR115. Preserve advanced Gnarly UI, omnibox, four REAL neural stems, saved cover/queue fixes. New branch fix/gnarly-build52-xr-performance-final.

Plan: measure CoreML CPU/GPU peak in separate macOS processes and preserve strict audio parity; choose memory-safe compute for XR; prevent low-memory kills; remove eager all-library cover migration, coalesce/decode off main with bounded cache; stop unnecessary dormant audio processing and constrain older-device live shader cadence. Test, build, inspect and deliver correct IPA52.

No paid APIs/server/PC for stems. Linux workspace lacks Xcode/device. GH macos-15 CI performs actual CoreML + iOSSimulator tests. User asked persistent completion; continue if compacted. No merge/main or backend changes.
