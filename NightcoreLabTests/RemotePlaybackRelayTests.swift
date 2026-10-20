import XCTest
import AVFoundation
import MediaPlayer
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

    func testSystemNextIsEnabledForQueuedTrackWithoutForwardHistory() throws {
        let source = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".caf")
        defer { try? FileManager.default.removeItem(at: source) }
        let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2)!
        do {
            let file = try AVAudioFile(forWriting: source, settings: format.settings)
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 128)!
            buffer.frameLength = 128
            try file.write(from: buffer)
        }
        let audio = AudioEngineManager(), coordinator = PlaybackCoordinator()
        let queue = PlaybackQueue(), navigation = PlaybackNavigationHistory()
        let queued = Track(id: "queued00001", title: "Queued", thumbnailURL: nil)
        queue.replace(with: [queued], excluding: "current")
        try audio.load(url: source)
        let relay = RemotePlaybackRelay()
        var selected: String?
        relay.connect { action in
            guard action == .next,
                  let next = coordinator.nextSelection(navigation: navigation, queue: queue) else { return false }
            selected = next.track.id
            return true
        }
        audio.connectRemoteCommands(relay)
        defer { audio.connectRemoteCommands(nil); relay.disconnect() }
        audio.updateRemoteCommandAvailability(canSkipNext:
            coordinator.nextSelection(navigation: navigation, queue: queue) != nil)
        XCTAssertTrue(MPRemoteCommandCenter.shared().nextTrackCommand.isEnabled)
        XCTAssertTrue(relay.dispatch(.next))
        XCTAssertEqual(selected, queued.id)
        XCTAssertEqual(queue.tracks, [queued], "The command stages selection; only playback confirmation consumes it")
        queue.clear()
        audio.updateRemoteCommandAvailability(canSkipNext:
            coordinator.nextSelection(navigation: navigation, queue: queue) != nil)
        XCTAssertFalse(MPRemoteCommandCenter.shared().nextTrackCommand.isEnabled)
    }
}
