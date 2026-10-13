# Stage 17B — Search & Session Robustness

This change is based on **Stage 17A** branch, and is intentionally a
stacked PR. It must be merged only after Stage 16A and Stage 17A have passed
the reviewed release gates. Inspiration: Spotifast's event-driven backend,
account-scoped cached snapshots and resilient loading states. No Rust source
or Spotify integration was copied.

## Implementation

### Omnibox

- Retains the existing URLSession, metadata ranker, NSCache (100 keys),
  220-ms debounce, historical/local instant results and YouTube backend.
- Every query and server URL change invalidates a UUID request generation;
  late responses cannot overwrite or populate cache of a newer request,
  even if transport cancellation is ineffective.
- Both /v1/search and /v1/suggest load concurrently; first successful
  response is shown immediately as **partial**, without awaiting the other.
- Explicit observable states: idle, local, loading, partial, ready and failed.
  Old UI compatibility flags (isSearching, hasSearched, lastRequestFailed)
  stay available and are synchronized.
- Cache: **5 minutes fresh**, then stale-while-revalidate until **24 hours**;
  expired entries are ignored. If refresh fails, previous valid cached hits
  stay visible with honest UI labeling; an unavailable suggestion endpoint
  never discards a successful music search.
- Changes to backend URL clear results and cache so environments cannot leak
  into one another. Cache entries hold only public track metadata and
  suggestions; no tokens, credentials or user tracking.
- The URLSession and monotonic debounce are injectable for deterministic
  in-process HTTP tests; no new package added.

### Session

- The existing UserDefaults key \`nightcore.lastPlaybackSession\` and
  \`track\` / \`position\` payload are unchanged. Added \`schemaVersion = 2\`.
- The new decoder accepts previous unversioned v1 sessions and current v2,
  sanitizes saved positions, and rejects unsupported future versions without
  corrupting stored data.
- V2 encoding adds only a JSON key; older synthesized Codable readers should
  ignore that additional field. No second copy or migration job is needed.
- Audio files, security-scoped URLs, OAuth tokens and queue snapshots remain
  excluded from the saved session.

## Validation and non-goals

- New Omnibox robustness tests exercise TTL boundaries, out-of-order
  responses, partial results, partial failures, stale-fallback and server
  scope. A URLProtocol stub intercepts requests; no production API calls.
- Session regression tests cover v2 encoding, legacy v1 decoding and unknown
  schema refusal. Existing tests remain unchanged.
- Python full test suite, complete XCTest, XcodeGen, Debug/Release, IPA and
  karaoke must pass for the current SHA. All tests run through Actions on PR.
- No additional AVAudioEngine node, shader, tap, Spotify gateway, new UI
  layout, dependency or PrivacyInfo.xcprivacy change.
- Later follow-up: quantify search latency/cache hit rate in device runs,
  evaluate disk-cache size / artwork LRU, improve route-change and
  lock-screen controls, measure preview/export parity.
