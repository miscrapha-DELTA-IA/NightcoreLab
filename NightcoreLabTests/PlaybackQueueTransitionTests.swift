import XCTest
@testable import NightcoreLab

@MainActor
final class PlaybackQueueTransitionTests: XCTestCase {
    private func track(_ id: String) -> Track {
        Track(id: id, title: "Song \(id)", thumbnailURL: nil)
    }

    func testSelectingMiddleEntryRetainsRemainingQueue() {
        let queue = PlaybackQueue()
        let a = track("aaaaaaaaaaa"), b = track("bbbbbbbbbbb")
        let c = track("ccccccccccc"), d = track("ddddddddddd")
        queue.replace(with: [b, c, d], excluding: a.id)
        XCTAssertNotNil(queue.select(c))
        XCTAssertEqual(queue.upNextQueue.map(\.id), [d.id])
    }

    func testUnknownEntryDoesNotMutateQueue() {
        let queue = PlaybackQueue()
        let a = track("aaaaaaaaaaa"), b = track("bbbbbbbbbbb")
        queue.replace(with: [b], excluding: a.id)
        XCTAssertNil(queue.select(a))
        XCTAssertEqual(queue.upNextQueue.map(\.id), [b.id])
    }
}
