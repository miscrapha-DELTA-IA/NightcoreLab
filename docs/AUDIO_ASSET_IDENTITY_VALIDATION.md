# Etapa 12.5 — Audio asset identity validation

## Root cause

AssetIdentityCache accepted URL + FileStamp (byte length, modification time, inode)
as sufficient to return a previously hashed AudioAssetDescriptor. validate(_:)
made the same metadata-only assumption. In-place byte edits with restored
timestamps reused the old sourceRevision and MusicAnalysisCache returned the
old energy/onset/rhythm data for a different audio payload.

The CI failure on Stage 12.5 was MusicIntelligenceTests.
testSameURLSameSizeAndDateWithChangedContentInvalidatesCache. The separate
main failure was a half-tempo tie in RhythmAnalyzerTests, addressed by PR #37.

## Identity contract (fail closed)

- assetID: SHA-256 of canonical source URL (stable locator).
- sourceRevision: SHA-256 of **all file bytes**, not partial samples.
- Cold lookup: inspect audio format and compute SHA-256 once using 1 MiB chunks.
- Warm lookup: compare metadata for a cheap preliminary check, but always
  stream SHA-256 once before accepting the descriptor. If the hash differs,
  invalidate the in-memory entry and reopen the file; a corrupt replacement
  fails rather than inheriting cached analysis.
- validate(_:) always recomputes the full digest before cache-hit publication,
  partial publication after FFT and final persistence; a matching stamp never
  bypasses content validation.
- MusicAnalysisCache continues comparing sourceRevision and schema/algorithm
  versions before returning persisted results. AnalysisScheduler still shares
  work for concurrent requests to the same canonical source URL.

**Guarantee boundary:** no ordinary access trusts stale metadata. As with
other file-based analyses, an external concurrent writer can race with bytes
being read; obtaining a coherent immutable snapshot or holding an exclusive
source lock is required to eliminate arbitrary TOCTOU mutations altogether.

## Performance (analytical, not benchmarked)

- Cold descriptor: one O(file size) SHA-256 pass, as before.
- Warm descriptor: one O(file size) streaming pass; previously O(1).
- Cache hit: one descriptor pass plus one final validation pass, both bounded
  to 1 MiB read chunks. The FFT and rhythm calculations are still skipped.
- Cache miss: final source validations cost sequential I/O; decode/FFT/rhythm
  dominate on typical new analyses, but large files may show higher latency.
- Same-key in-flight requests share descriptor/digest and analysis work;
  their number does not multiply the hashing cost while the job is active.

No partial hash or time-based sampling can guarantee immediate invalidation
after an adversarial same-stamp edit, so correctness takes precedence.

## Verification gates

1. Repeated unchanged audio uses persistent cache without re-running FFT.
2. In-place same-URL/same-size/same-mtime/same-inode edits change revision.
3. Corrupt audio header with restored stamp cannot reuse cached analysis.
4. Eight simultaneous requests share one in-flight decode/FFT job.
5. Existing checks: source change during analysis, damaged JSON cache,
   missing audio, onsets retry, Rhythm v3 and Creative Experience parity.
6. xcodegen, complete simulator XCTest, Release build, unsigned IPA via
   .github/workflows/ios.yml on macOS.

Do not mark Stage 12.5 complete or begin Stage 13 until the full workflow is
green and PR #37 then #38 are integrated.
