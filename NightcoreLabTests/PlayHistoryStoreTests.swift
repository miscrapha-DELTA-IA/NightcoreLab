import XCTest
@testable import NightcoreLab

final class PlayHistoryStoreTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private func track(_ id: String) -> Track {
        Track(id: id, title: "Artist - \(id)", thumbnailURL: nil)
    }
    private func hit(_ id: String) -> TrackHit {
        TrackHit(id: id, title: id, artist: "Artist", album: nil, duration: 180,
                 thumb: nil, isSong: true, explicit: false)
    }
    @MainActor
    private func withStore(_ body: (PlayHistoryStore, UserDefaults) throws -> Void) rethrows {
        let suite = "PlayHistoryStoreTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        try body(PlayHistoryStore(defaults: defaults), defaults)
    }

    @MainActor
    func testOriginalJSONWithoutNewFieldsStillLoads() throws {
        try withStore { _, defaults in
            // Encode only the original schema, without relying on the new initializer.
            struct Legacy: Codable { let hit: TrackHit; let plays: Int; let lastPlayed: Date }
            let data = try JSONEncoder().encode(["a": Legacy(hit: hit("a"), plays: 4, lastPlayed: now)])
            defaults.set(data, forKey: PlayHistoryStore.defaultsKey)
            let restored = PlayHistoryStore(defaults: defaults)
            XCTAssertEqual(restored.entries["a"]?.plays, 4)
            XCTAssertNil(restored.entries["a"]?.completions)
            XCTAssertNil(restored.entries["a"]?.earlySkips)
            restored.recordCompletion("a")
            XCTAssertEqual(PlayHistoryStore(defaults: defaults).entries["a"]?.completions, 1)
        }
    }

    @MainActor
    func testStartsCompletionsAndSkipsSurviveReload() {
        withStore { store, defaults in
            store.recordStart(hit("a"), now: now)
            store.recordCompletion("a")
            store.recordEarlySkip("a", now: now)
            store.recordStart(hit("a"), now: now.addingTimeInterval(100))
            let entry = PlayHistoryStore(defaults: defaults).entries["a"]
            XCTAssertEqual(entry?.plays, 2)
            XCTAssertEqual(entry?.completions, 1)
            XCTAssertEqual(entry?.earlySkips, 1)
            XCTAssertEqual(entry?.lastSkippedAt, now)
            XCTAssertEqual(entry?.lastPlayed, now.addingTimeInterval(100))
        }
    }

    @MainActor
    func testPrunesTo100MostRecentlyPlayedTracks() {
        withStore { store, _ in
            for index in 0..<105 { store.recordStart(hit("t\(index)"), now: now.addingTimeInterval(Double(index))) }
            XCTAssertEqual(store.entries.count, 100)
            XCTAssertNil(store.entries["t0"])
            XCTAssertNotNil(store.entries["t104"])
            store.recordStart(hit("t5"), now: now.addingTimeInterval(200))
            store.recordStart(hit("new"), now: now.addingTimeInterval(201))
            XCTAssertNotNil(store.entries["t5"])
            XCTAssertNil(store.entries["t6"])
        }
    }

    @MainActor
    func testFailedOrCancelledSelectionDoesNotCountSkipOrStart() {
        withStore { store, _ in
            store.beginPlayback(track("a"), sourceDuration: 180, now: now)
            let pending = store.pendingSkip(position: 3, duration: 180, automaticAdvance: false)
            XCTAssertNotNil(pending)
            // Failure does not call beginPlayback for the replacement.
            XCTAssertEqual(store.entries["a"]?.plays, 1)
            XCTAssertNil(store.entries["a"]?.earlySkips)
            XCTAssertNil(store.entries["b"])
            store.beginPlayback(track("b"), sourceDuration: 180, replacing: pending, now: now)
            XCTAssertEqual(store.entries["a"]?.earlySkips, 1)
            XCTAssertEqual(store.entries["b"]?.plays, 1)
        }
    }

    @MainActor
    func testCompletionDuringDownloadSuppressesPendingSkip() {
        withStore { store, _ in
            store.beginPlayback(track("a"), sourceDuration: 180, now: now)
            let pending = store.pendingSkip(position: 3, duration: 180, automaticAdvance: false)
            store.completePlayback(trackID: "a")
            store.completePlayback(trackID: "a")
            store.beginPlayback(track("b"), sourceDuration: 180, replacing: pending, now: now)
            XCTAssertNil(store.entries["a"]?.earlySkips)
            XCTAssertEqual(store.entries["a"]?.completions, 1)
        }
    }

    @MainActor
    func testStaleSelectionCannotPenalizeLaterSession() {
        withStore { store, _ in
            store.beginPlayback(track("a"), sourceDuration: 180, now: now)
            let pending = store.pendingSkip(position: 3, duration: 180, automaticAdvance: false)
            store.beginPlayback(track("c"), sourceDuration: 180, now: now)
            store.beginPlayback(track("b"), sourceDuration: 180, replacing: pending, now: now)
            XCTAssertNil(store.entries["a"]?.earlySkips)
            XCTAssertNil(store.entries["c"]?.earlySkips)
        }
    }

    @MainActor
    func testThresholdAutomaticAdvanceAndRestoredIdleTrackAreIgnored() {
        withStore { store, _ in
            XCTAssertNil(store.pendingSkip(position: 1, duration: 180, automaticAdvance: false))
            store.beginPlayback(track("a"), sourceDuration: 180, now: now)
            XCTAssertNil(store.pendingSkip(position: 10, duration: 180, automaticAdvance: false))
            XCTAssertNil(store.pendingSkip(position: 2, duration: 180, automaticAdvance: true))
            XCTAssertNil(store.pendingSkip(position: .nan, duration: 180, automaticAdvance: false))
            XCTAssertNil(store.pendingSkip(position: 3, duration: 3, automaticAdvance: false))
            store.endSession()
            XCTAssertNil(store.pendingSkip(position: 1, duration: 180, automaticAdvance: false))
        }
    }

    @MainActor
    func testPauseResumeDoesNotDoubleCountButReplayDoes() {
        withStore { store, _ in
            store.resumePlaybackIfNeeded(track("a"), sourceDuration: 180)
            store.resumePlaybackIfNeeded(track("a"), sourceDuration: 180)
            XCTAssertEqual(store.entries["a"]?.plays, 1)
            store.completePlayback(trackID: "a")
            store.resumePlaybackIfNeeded(track("a"), sourceDuration: 180)
            XCTAssertEqual(store.entries["a"]?.plays, 2)
        }
    }

    @MainActor
    func testURLReplayKeepsPreviouslyKnownMetadata() {
        withStore { store, _ in
            store.recordStart(hit("a"), now: now)
            store.beginPlayback(Track(id: "a", title: "a", thumbnailURL: nil), sourceDuration: nil, now: now)
            XCTAssertEqual(store.entries["a"]?.hit.artist, "Artist")
            XCTAssertEqual(store.entries["a"]?.hit.duration, 180)
        }
    }
}
