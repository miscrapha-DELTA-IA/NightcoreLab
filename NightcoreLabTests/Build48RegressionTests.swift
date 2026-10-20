import XCTest
@testable import NightcoreLab

@MainActor
final class Build48RegressionTests: XCTestCase {
    func testSearchRestoresTypedQueryWithoutSubmitting() throws {
        let suite = "build48-search.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let session = SearchSession(defaults: defaults)
        session.query = "Paramore Decode"
        XCTAssertEqual(SearchSession(defaults: defaults).query, session.query)
        session.query = "https://youtu.be/abcdefghijk"
        XCTAssertEqual(session.savedQuery, "Paramore Decode")
    }

    func testMixAvoidsRecentFavoritesAtTheFrontAndRotates() {
        let first = DrawerSmartMix.resolve(history: [], cached: [], discovery: [], current: nil)
        let history = first.prefix(5).map { track in
            HistoryEntry(hit: TrackHit(id: track.id, title: track.title, artist: track.cleanArtist ?? "",
                album: nil, duration: 180, thumb: nil, isSong: true, explicit: false),
                plays: 100, lastPlayed: .now)
        }
        let next = DrawerSmartMix.resolve(history: history, cached: [], discovery: [], current: nil)
        XCTAssertTrue(Set(first.prefix(5).map(\.id)).isDisjoint(with: next.prefix(5).map(\.id)))
        let rotated = DrawerSmartMix.resolve(history: history, cached: [], discovery: [], current: nil, generation: 1)
        XCTAssertNotEqual(next.map(\.id), rotated.map(\.id))
        XCTAssertEqual(Set(rotated.map(\.id)).count, 15)
    }

    func testStoppingMicrophoneKeepsFrozenResult() throws {
        let session = KaraokeScoringSession()
        session.present(true)
        let lines = EnhancedLRCParser.parse("[00:00.00]Sing\n[00:02.00]Again").lines
        session.start(mode: .simulation, lines: lines, at: 0)
        for step in 1...30 { session.advance(time: Double(step) / 20, playing: true, lines: lines) }
        session.stop()
        let saved = try XCTUnwrap(session.lastResult)
        XCTAssertTrue(saved.snapshot.isFinished)
        XCTAssertGreaterThan(saved.snapshot.totalScore, 0)
        XCTAssertEqual(saved.mode, .simulation)
        session.present(false)
        XCTAssertEqual(session.lastResult?.snapshot, saved.snapshot)
    }

    func testPreviousSongCannotReplaceNewLyrics() async throws {
        let store = LyricsStore()
        store.beginLoading(trackID: "new")
        store.loadIfCurrent(trackID: "old", rawLRC: "[00:00.00]Old song", force: true)
        XCTAssertEqual(store.trackID, "new")
        XCTAssertTrue(store.lines.isEmpty)
        store.loadIfCurrent(trackID: "new", rawLRC: "[00:00.00]New song")
        store.beginLoading(trackID: "new")
        for _ in 0..<100 where store.status != .ready {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(store.lines.first?.text, "New song")
    }
}
