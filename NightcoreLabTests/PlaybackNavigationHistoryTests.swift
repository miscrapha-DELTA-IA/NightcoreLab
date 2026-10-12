import XCTest
@testable import NightcoreLab

@MainActor
final class PlaybackNavigationHistoryTests: XCTestCase {
    private func track(_ id: String) -> Track {
        Track(id: id, title: "Faixa \(id)", thumbnailURL: nil)
    }

    func testPreviousReturnsToActualLastPlayedTrackAndNextReturnsForward() {
        let history = PlaybackNavigationHistory()
        let a = track("aaaaaaaaaaa"), b = track("bbbbbbbbbbb"), c = track("ccccccccccc")

        history.commitStarted(a, replacing: nil)
        history.commitStarted(b, replacing: a)
        history.commitStarted(c, replacing: b)
        XCTAssertEqual(history.previous.map(\.id), [a.id, b.id])
        XCTAssertEqual(history.previousTrack?.id, b.id)

        history.commitStarted(b, replacing: c, direction: .backward)
        XCTAssertEqual(history.previousTrack?.id, a.id)
        XCTAssertEqual(history.forwardTrack?.id, c.id)

        history.commitStarted(a, replacing: b, direction: .backward)
        XCTAssertNil(history.previousTrack)
        XCTAssertEqual(history.forward.map(\.id), [c.id, b.id])

        history.commitStarted(b, replacing: a, direction: .forward)
        XCTAssertEqual(history.previousTrack?.id, a.id)
        XCTAssertEqual(history.forwardTrack?.id, c.id)

        history.commitStarted(c, replacing: b, direction: .forward)
        XCTAssertEqual(history.previous.map(\.id), [a.id, b.id])
        XCTAssertNil(history.forwardTrack)
    }

    func testSelectedTrackMustActuallyStartBeforeHistoryIsCommitted() {
        let history = PlaybackNavigationHistory()
        let a = track("aaaaaaaaaaa"), b = track("bbbbbbbbbbb")
        history.commitStarted(a, replacing: nil)

        // Starting a download, failing to play, or cancelling a selection
        // does not call commitStarted and must never move history.
        XCTAssertNil(history.previousTrack)
        history.commitStarted(b, replacing: a)
        XCTAssertEqual(history.previousTrack?.id, a.id)

        // A failed previous selection leaves the target available.
        XCTAssertEqual(history.previousTrack?.id, a.id)
        XCTAssertNil(history.forwardTrack)
        history.commitStarted(a, replacing: b, direction: .backward)
        XCTAssertEqual(history.forwardTrack?.id, b.id)
    }

    func testRegularSelectionAfterGoingBackClearsForwardBranch() {
        let history = PlaybackNavigationHistory()
        let a = track("aaaaaaaaaaa"), b = track("bbbbbbbbbbb"), c = track("ccccccccccc")
        history.commitStarted(a, replacing: nil)
        history.commitStarted(b, replacing: a)
        history.commitStarted(a, replacing: b, direction: .backward)
        XCTAssertEqual(history.forwardTrack?.id, b.id)

        history.commitStarted(c, replacing: a)
        XCTAssertNil(history.forwardTrack)
        XCTAssertEqual(history.previous.map(\.id), [a.id])
    }

    func testReplayingSameTrackDoesNotCreatePhantomPreviousEntry() {
        let history = PlaybackNavigationHistory()
        let a = track("aaaaaaaaaaa"), b = track("bbbbbbbbbbb")
        history.commitStarted(a, replacing: nil)
        history.commitStarted(a, replacing: a)
        XCTAssertNil(history.previousTrack)
        history.commitStarted(b, replacing: a)
        history.commitStarted(b, replacing: b)
        XCTAssertEqual(history.previous.map(\.id), [a.id])
    }

    func testFailedOrStaleNavigationDoesNotPopHistory() {
        let history = PlaybackNavigationHistory()
        let a = track("aaaaaaaaaaa"), b = track("bbbbbbbbbbb"), c = track("ccccccccccc")
        history.commitStarted(a, replacing: nil)
        history.commitStarted(b, replacing: a)

        // A stale callback for a different navigation target is ignored.
        history.commitStarted(c, replacing: b, direction: .backward)
        XCTAssertEqual(history.previousTrack?.id, a.id)
        XCTAssertNil(history.forwardTrack)
    }

    func testQueueIsIndependentOfNavigationHistory() {
        let queue = PlaybackQueue()
        let history = PlaybackNavigationHistory()
        let a = track("aaaaaaaaaaa"), b = track("bbbbbbbbbbb"), c = track("ccccccccccc")
        queue.replace(with: [b, c], excluding: a.id)
        history.commitStarted(a, replacing: nil)
        history.commitStarted(b, replacing: a)
        XCTAssertTrue(queue.commitPlaying(b))
        XCTAssertEqual(queue.tracks.map(\.id), [c.id])

        history.commitStarted(a, replacing: b, direction: .backward)
        history.commitStarted(b, replacing: a, direction: .forward)
        XCTAssertEqual(queue.tracks.map(\.id), [c.id],
                       "Back/forward navigation must not consume the recommendation queue.")
    }

    func testHistoryIsBoundedAndClearedWhenLocalFileReplacesPlayback() {
        let history = PlaybackNavigationHistory()
        var current = track("firstfirst1")
        history.commitStarted(current, replacing: nil)
        for i in 0..<100 {
            let next = track(String(format: "track%06d", i))
            history.commitStarted(next, replacing: current)
            current = next
        }
        XCTAssertEqual(history.previous.count, PlaybackNavigationHistory.limit)
        history.clear()
        XCTAssertNil(history.previousTrack)
        XCTAssertNil(history.forwardTrack)
    }
}
