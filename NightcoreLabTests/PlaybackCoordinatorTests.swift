import Foundation
import XCTest
@testable import NightcoreLab

@MainActor
final class PlaybackCoordinatorTests: XCTestCase {
    private func track(_ id: String) -> Track {
        Track(id: id, title: "Track \(id)", thumbnailURL: nil)
    }

    func testLoadingIsIntentUntilEngineConfirmsAndStaleCallbacksCannotWin() {
        let coordinator = PlaybackCoordinator()
        let first = coordinator.begin(trackID: "old")
        XCTAssertEqual(coordinator.transportState, .loading("old"))
        XCTAssertEqual(coordinator.requestedCommand, .select("old"))
        let latest = coordinator.begin(trackID: "new")
        XCTAssertFalse(coordinator.didStart(first, trackID: "old"))
        XCTAssertFalse(coordinator.didFail(first, trackID: "old"))
        XCTAssertEqual(coordinator.transportState, .loading("new"))
        XCTAssertTrue(coordinator.didStart(latest, trackID: "new"))
        XCTAssertEqual(coordinator.transportState, .playing("new"))
        XCTAssertNil(coordinator.requestedCommand)
    }

    func testFailureAndRetryDoNotConsumeQueue() {
        let coordinator = PlaybackCoordinator()
        let queue = PlaybackQueue()
        let one = track("abcdefghijk")
        queue.replace(with: [one], excluding: "other")
        let first = coordinator.begin(trackID: one.id)
        XCTAssertTrue(coordinator.didFail(first, trackID: one.id))
        XCTAssertEqual(coordinator.transportState, .failed(one.id))
        XCTAssertEqual(queue.upNextQueue.map(\.id), [one.id])
        let retry = coordinator.begin(trackID: one.id)
        XCTAssertTrue(coordinator.didStart(retry, trackID: one.id))
        XCTAssertTrue(queue.contains(one))
    }

    func testConfirmedPlaybackPauseResumeAndEnd() {
        let coordinator = PlaybackCoordinator()
        let token = coordinator.begin(trackID: "a")
        XCTAssertTrue(coordinator.didStart(token, trackID: "a"))
        coordinator.confirmPlayback(isPlaying: false, trackID: "a")
        XCTAssertEqual(coordinator.transportState, .paused("a"))
        coordinator.confirmPlayback(isPlaying: true, trackID: "a")
        XCTAssertEqual(coordinator.transportState, .playing("a"))
        coordinator.didEnd(trackID: "a")
        XCTAssertEqual(coordinator.transportState, .ended("a"))
        coordinator.reset()
        XCTAssertEqual(coordinator.transportState, .idle)
    }

    func testConfirmedStartCommitsOnlyChosenQueueEntry() {
        let coordinator = PlaybackCoordinator()
        let navigation = PlaybackNavigationHistory()
        let queue = PlaybackQueue()
        let previous = track("11111111111")
        let selected = track("22222222222")
        let remaining = track("33333333333")
        queue.replace(with: [selected, remaining], excluding: previous.id)
        let token = coordinator.begin(trackID: selected.id)
        XCTAssertEqual(queue.upNextQueue.map(\.id), [selected.id, remaining.id])
        XCTAssertTrue(coordinator.didStart(token, trackID: selected.id))
        coordinator.commitStarted(selected, replacing: previous, direction: .regular,
                                  queue: queue, navigation: navigation)
        XCTAssertEqual(queue.upNextQueue.map(\.id), [remaining.id])
        XCTAssertEqual(navigation.previousTrack?.id, previous.id)
        XCTAssertEqual(coordinator.previousCandidate(navigation: navigation)?.id, previous.id)
    }

    func testEnqueueClearAndExistingNavigationPreserved() {
        let coordinator = PlaybackCoordinator()
        let queue = PlaybackQueue()
        let navigation = PlaybackNavigationHistory()
        let a = track("aaaaaaaaaaa")
        let b = track("bbbbbbbbbbb")
        coordinator.enqueue([a, a, b], excluding: "other", queue: queue)
        XCTAssertEqual(queue.upNextQueue.map(\.id), [a.id, b.id])
        XCTAssertEqual(coordinator.nextCandidate(navigation: navigation, queue: queue)?.id, a.id)
        coordinator.clearQueue(queue)
        XCTAssertTrue(queue.upNextQueue.isEmpty)
    }

    func testSourceIdentityIsNamespacedAndLegacyTrackCodableIsUnchanged() throws {
        let youtube = TrackIdentity(source: .youtube, sourceID: "abcdefghijk")
        let spotify = TrackIdentity(source: .spotify, sourceID: "abcdefghijk")
        let local = TrackIdentity(source: .local, sourceID: "abcdefghijk")
        XCTAssertNotEqual(youtube, spotify)
        XCTAssertNotEqual(local, youtube)
        XCTAssertEqual(try JSONDecoder().decode(TrackIdentity.self,
            from: JSONEncoder().encode(spotify)), spotify)

        let original = track("abcdefghijk")
        XCTAssertEqual(original.identity, youtube)
        let encoded = try JSONEncoder().encode(original)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        XCTAssertNil(object["source"], "Old sessions must not gain a mandatory field")
        XCTAssertEqual(try JSONDecoder().decode(Track.self, from: encoded), original)
    }
}
