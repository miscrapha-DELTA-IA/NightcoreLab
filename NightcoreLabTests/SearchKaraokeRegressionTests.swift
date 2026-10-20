import XCTest
@testable import NightcoreLab

@MainActor
final class SearchKaraokeRegressionTests: XCTestCase {
    func testTypedQueryRestoresWithoutSubmittingAndDirectLinksDoNotEraseIt() throws {
        let suite = "search-session.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let session = SearchSession(defaults: defaults)
        session.query = "  Paramore Decode  "
        session.searchResults = [Track(id: "abcdefghijk", title: "Decode", thumbnailURL: nil)]
        let reopened = SearchSession(defaults: defaults)
        XCTAssertEqual(reopened.query, "Paramore Decode")
        session.query = "https://youtu.be/abcdefghijk"
        XCTAssertEqual(session.savedQuery, "Paramore Decode")
        XCTAssertEqual(session.searchResults.first?.title, "Decode")
        session.query = ""
        XCTAssertEqual(SearchSession(defaults: defaults).query, "")
    }

    func testResultSurvivesClosingKaraokeAndAutomaticTrackAdvance() throws {
        let session = KaraokeScoringSession()
        let lines = [TimedLyricLine(id: 0, start: 0, end: 2,
            words: [WordSync(id: 0, text: "Sing", start: 0, end: 2, spaceAfter: false)], precision: .word)]
        session.present(true)
        session.start(mode: .simulation, lines: lines, at: 0, trackTitle: "First song")
        for step in 1...20 { session.advance(time: Double(step) / 20, playing: true, lines: lines) }
        session.stop()
        let result = try XCTUnwrap(session.lastResult)
        XCTAssertTrue(result.snapshot.isFinished)
        XCTAssertGreaterThan(result.snapshot.totalScore, 0)
        XCTAssertTrue(result.simulation)
        XCTAssertEqual(session.mode, .off)
        session.present(false)
        session.present(true)
        XCTAssertEqual(session.lastResult?.id, result.id)
        XCTAssertEqual(session.lastResult?.snapshot, result.snapshot)
        session.resetForTrack()
        XCTAssertEqual(session.lastResult?.trackTitle, "First song")
        XCTAssertEqual(session.lastResult?.snapshot, result.snapshot)
        session.start(mode: .simulation, lines: lines, at: 0, trackTitle: "Next song")
        session.finish()
        XCTAssertEqual(session.lastResult?.trackTitle, "Next song")
    }

    func testLateLyricsCannotReplaceCurrentTrackAndNewTrackClearsImmediately() async throws {
        let store = LyricsStore()
        store.beginLoading(trackID: "old")
        store.loadIfCurrent(trackID: "old", rawLRC: "[00:01.00]Old song")
        for _ in 0..<100 where store.status != .ready {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertFalse(store.lines.isEmpty)
        store.beginLoading(trackID: "new", clearExisting: true)
        XCTAssertTrue(store.lines.isEmpty)
        store.loadIfCurrent(trackID: "old", rawLRC: "[00:01.00]Late old song", force: true)
        XCTAssertEqual(store.trackID, "new")
        XCTAssertTrue(store.lines.isEmpty)
        store.loadIfCurrent(trackID: "new", rawLRC: "[00:01.00]New song")
        // Joining the existing request must not cancel its detached parser.
        store.beginLoading(trackID: "new")
        for _ in 0..<100 where store.status != .ready {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(store.lines.first?.text, "New song")
    }
}
