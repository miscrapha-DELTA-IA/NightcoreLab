import AVFoundation
import XCTest
@testable import NightcoreLab

@MainActor
final class PlaybackQueueTransitionTests: XCTestCase {
    private func track(_ id: String) -> Track {
        Track(id: id, title: "Song \(id)", thumbnailURL: nil)
    }

    func testFirstQueueEntryIsNotRemovedDuringPreparation() {
        let queue = PlaybackQueue()
        let first = track("aaaaaaaaaaa"), second = track("bbbbbbbbbbb")
        queue.replace(with: [first, second], excluding: "ccccccccccc")
        XCTAssertEqual(queue.remaining(after: first)?.map(\.id), [second.id])
        XCTAssertEqual(queue.upNextQueue.map(\.id), [first.id, second.id])
        XCTAssertTrue(queue.commitPlaying(first))
        XCTAssertEqual(queue.upNextQueue.map(\.id), [second.id])
    }

    func testMiddleEntryCommitsOnlyAfterPlayback() {
        let queue = PlaybackQueue()
        let a = track("aaaaaaaaaaa"), b = track("bbbbbbbbbbb"), c = track("ccccccccccc")
        queue.replace(with: [a,b,c], excluding: "ddddddddddd")
        XCTAssertEqual(queue.remaining(after: b)?.map(\.id), [c.id])
        XCTAssertEqual(queue.upNextQueue.count, 3)
        XCTAssertTrue(queue.commitPlaying(b))
        XCTAssertEqual(queue.upNextQueue.map(\.id), [c.id])
    }

    func testFailurePreservesQueueAndAllowsRetry() {
        let queue = PlaybackQueue()
        let item = track("aaaaaaaaaaa")
        let transition = PlaybackTransitionCoordinator()
        queue.replace(with: [item], excluding: "bbbbbbbbbbb")
        let request = transition.begin(trackID: item.id)
        XCTAssertTrue(transition.didFail(request, trackID: item.id))
        XCTAssertEqual(queue.upNextQueue.map(\.id), [item.id])
        let retry = transition.begin(trackID: item.id)
        XCTAssertTrue(transition.didStart(retry, trackID: item.id))
        XCTAssertTrue(queue.commitPlaying(item))
        XCTAssertTrue(queue.upNextQueue.isEmpty)
    }

    func testStaleCompletionCannotCommitQueue() {
        let transition = PlaybackTransitionCoordinator()
        let old = track("aaaaaaaaaaa"), next = track("bbbbbbbbbbb")
        let queue = PlaybackQueue()
        queue.replace(with: [old, next], excluding: "ccccccccccc")
        let staleToken = transition.begin(trackID: old.id)
        let latest = transition.begin(trackID: next.id)
        XCTAssertFalse(transition.didStart(staleToken, trackID: old.id))
        XCTAssertFalse(transition.didFail(staleToken, trackID: old.id))
        XCTAssertEqual(queue.upNextQueue.map(\.id), [old.id, next.id])
        XCTAssertTrue(transition.didStart(latest, trackID: next.id))
        XCTAssertTrue(queue.commitPlaying(next))
        XCTAssertTrue(queue.upNextQueue.isEmpty)
    }

    func testUnknownQueueEntryDoesNotMutate() {
        let queue = PlaybackQueue()
        let a = track("aaaaaaaaaaa"), b = track("bbbbbbbbbbb")
        queue.replace(with: [b], excluding: a.id)
        XCTAssertNil(queue.remaining(after: a))
        XCTAssertFalse(queue.commitPlaying(a))
        XCTAssertEqual(queue.upNextQueue.map(\.id), [b.id])
    }

    func testPlaybackBeginsBeforeQueueCommitWithLocalAudio() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2))
        let local = folder.appendingPathComponent("audio.caf")
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 44_100))
        buffer.frameLength = 44_100
        for channel in 0..<2 {
            for frame in 0..<44_100 {
                buffer.floatChannelData![channel][frame] = 0.05
            }
        }
        let file = try AVAudioFile(forWriting: local, settings: format.settings)
        try file.write(from: buffer)
        let queue = PlaybackQueue()
        let item = track("aaaaaaaaaaa")
        queue.replace(with: [item], excluding: "bbbbbbbbbbb")
        let audio = AudioEngineManager()
        try audio.load(url: local)
        XCTAssertEqual(queue.upNextQueue.map(\.id), [item.id])
        audio.play()
        XCTAssertTrue(audio.isPlaying, "Queue commit requires actual audio playback")
        XCTAssertTrue(queue.commitPlaying(item))
        XCTAssertTrue(queue.upNextQueue.isEmpty)
        audio.pause()
    }

    func testCachedTrackUsesLocalURLWithoutNetwork() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        // The cache exposes a local URL without constructing a download URL.
        var cache = TrackAudioCache(folder: root.appendingPathComponent("cache"))
        let item = track("aaaaaaaaaaa")
        let local = root.appendingPathComponent("source.caf")
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2))
        let file = try AVAudioFile(forWriting: local, settings: format.settings)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 128))
        buffer.frameLength = 128
        try file.write(from: buffer)
        let cached = try cache.store(item, from: local)
        XCTAssertEqual(cache.localURL(for: item.id), cached)
    }

    func testAutomaticNextTrackStagesWithoutRemoving() {
        let queue = PlaybackQueue()
        let first = track("aaaaaaaaaaa"), second = track("bbbbbbbbbbb")
        queue.replace(with: [first, second], excluding: "ccccccccccc")
        let automatic = queue.upNextQueue.first!
        XCTAssertEqual(automatic.id, first.id)
        XCTAssertEqual(queue.upNextQueue.count, 2)
        XCTAssertTrue(queue.commitPlaying(automatic))
        XCTAssertEqual(queue.upNextQueue.map(\.id), [second.id])
    }
    func testDiscoveryModeDisplaysOnlySearchResults() {
        let searched = track("aaaaaaaaaaa")
        let suggested = track("bbbbbbbbbbb")
        let visible = DiscoveryPresentation.visibleTracks(
            searchQuery: "music", searchResults: [searched], suggestions: [suggested])
        XCTAssertEqual(visible.map(\.id), [searched.id])
    }

    func testReturningToDiscoveryDoesNotMutateQueue() {
        let queue = PlaybackQueue()
        let searched = track("aaaaaaaaaaa")
        let suggested = track("bbbbbbbbbbb")
        queue.replace(with: [suggested], excluding: searched.id)
        _ = DiscoveryPresentation.visibleTracks(
            searchQuery: "music", searchResults: [searched], suggestions: [suggested])
        let shown = DiscoveryPresentation.visibleTracks(
            searchQuery: nil, searchResults: [searched], suggestions: [suggested])
        XCTAssertEqual(shown.map(\.id), [suggested.id])
        XCTAssertEqual(queue.upNextQueue.map(\.id), [suggested.id])
    }

}
