import XCTest
@testable import NightcoreLab

@MainActor
final class RemotePlaybackRelayTests: XCTestCase {
    func testRoutesOneActionAtATimeAndDisconnectsWithoutRetainingOldHandler() {
        let relay = RemotePlaybackRelay()
        var calls: [RemotePlaybackAction] = []
        XCTAssertFalse(relay.dispatch(.next))
        relay.connect { action in
            calls.append(action)
            return true
        }
        XCTAssertTrue(relay.dispatch(.play))
        XCTAssertTrue(relay.dispatch(.pause))
        XCTAssertTrue(relay.dispatch(.toggle))
        XCTAssertTrue(relay.dispatch(.previous))
        XCTAssertTrue(relay.dispatch(.next))
        XCTAssertTrue(relay.dispatch(.seek(120.25)))
        XCTAssertEqual(calls, [.play, .pause, .toggle, .previous, .next, .seek(120.25)])
        relay.disconnect()
        XCTAssertFalse(relay.dispatch(.next))
        XCTAssertEqual(calls.count, 6)
    }

    func testDeniedNavigationIsNotReportedAsAccepted() {
        let relay = RemotePlaybackRelay()
        relay.connect { action in action != .next && action != .previous }
        XCTAssertFalse(relay.dispatch(.next))
        XCTAssertFalse(relay.dispatch(.previous))
        XCTAssertTrue(relay.dispatch(.play))
    }

    func testResumeRequiresSystemPermissionSameSourceAndPriorPlayback() {
        XCTAssertTrue(AudioInterruptionResumePolicy.shouldResume(
            wasPlaying: true, systemAllows: true, sameSource: true, userOverrode: false))
        XCTAssertFalse(AudioInterruptionResumePolicy.shouldResume(
            wasPlaying: false, systemAllows: true, sameSource: true, userOverrode: false))
        XCTAssertFalse(AudioInterruptionResumePolicy.shouldResume(
            wasPlaying: true, systemAllows: false, sameSource: true, userOverrode: false))
        XCTAssertFalse(AudioInterruptionResumePolicy.shouldResume(
            wasPlaying: true, systemAllows: true, sameSource: false, userOverrode: false))
        XCTAssertFalse(AudioInterruptionResumePolicy.shouldResume(
            wasPlaying: true, systemAllows: true, sameSource: true, userOverrode: true))
    }
}
