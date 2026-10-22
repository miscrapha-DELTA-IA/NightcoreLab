import Foundation
import Combine
import DownloadKit
import XCTest
@testable import NightcoreLab

private final class DownloadRequestProbe: @unchecked Sendable {
    static let shared = DownloadRequestProbe()
    private let lock = NSLock()
    private var starts: [String: Int] = [:]
    private var stops: [String: Int] = [:]
    private var rejected = Set<String>()
    func record(_ request: URLRequest, stopped: Bool) {
        guard let source = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == "url" })?.value,
              let id = URLComponents(string: source)?.queryItems?.first(where: { $0.name == "v" })?.value else { return }
        lock.lock(); defer { lock.unlock() }
        if stopped { stops[id, default: 0] += 1 }
        else { starts[id, default: 0] += 1 }
    }
    func counts(_ id: String) -> (starts: Int, stops: Int) {
        lock.lock(); defer { lock.unlock() }
        return (starts[id, default: 0], stops[id, default: 0])
    }
    func reject(_ id: String) {
        lock.lock(); defer { lock.unlock() }
        rejected.insert(id)
    }
    func shouldReject(_ request: URLRequest) -> Bool {
        guard let url = request.url,
              let source = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "url" })?.value,
              let id = URLComponents(string: source)?.queryItems?.first(where: { $0.name == "v" })?.value else { return false }
        lock.lock(); defer { lock.unlock() }
        return rejected.contains(id)
    }
}

/// Hold transfers open without network or audio, observing actual cancellation.
private final class HeldAudioProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        DownloadRequestProbe.shared.record(request, stopped: false)
        if DownloadRequestProbe.shared.shouldReject(request) {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost))
        }
    }
    override func stopLoading() { DownloadRequestProbe.shared.record(request, stopped: true) }
}

@MainActor
final class DownloadIndependenceTests: XCTestCase {
    private func manager(cached: [Track] = [], cacheFolder: URL? = nil) async throws -> AudioDownloadManager {
        let folder = cacheFolder ?? FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        var cache = TrackAudioCache(folder: folder)
        for track in cached {
            let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try Data(("RIFF" + String(repeating: "x", count: 32)).utf8).write(to: file)
            _ = try cache.store(track, from: file)
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [HeldAudioProtocol.self]
        let manager = AudioDownloadManager(configuration: configuration, cacheFolder: folder)
        addTeardownBlock {
            await MainActor.run { manager.cancel() }
            try? FileManager.default.removeItem(at: folder)
        }
        let ready = expectation(description: "Cache index loaded")
        let subscription = manager.$isCacheReady.first(where: { $0 }).sink { _ in ready.fulfill() }
        defer { subscription.cancel() }
        await fulfillment(of: [ready], timeout: 5)
        return manager
    }

    private func track() -> Track {
        Track(id: String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(11)),
              title: "Test", thumbnailURL: nil)
    }

    private func waitForStart(_ id: String) async throws {
        for _ in 0..<100 {
            if DownloadRequestProbe.shared.counts(id).starts > 0 { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("The selected transfer did not start")
    }

    func testPlayingAnotherTrackKeepsOfflineDownloadRunningAndReusesSameTrack() async throws {
        let manager = try await manager()
        let offline = track(), selected = track()
        Task { _ = try? await manager.saveOfflineAudio(offline) }
        try await waitForStart(offline.id)
        manager.select(selected, onReady: { _, _ in XCTFail("Held request cannot finish") })
        try await waitForStart(selected.id)
        XCTAssertEqual(manager.downloadingIDs, [offline.id, selected.id])
        XCTAssertEqual(DownloadRequestProbe.shared.counts(offline.id).stops, 0)
        manager.select(offline, onReady: { _, _ in XCTFail("Held request cannot finish") })
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(DownloadRequestProbe.shared.counts(offline.id).starts, 1)
        XCTAssertEqual(DownloadRequestProbe.shared.counts(selected.id).stops, 0)
        manager.cancelPlaybackSelection()
        XCTAssertEqual(DownloadRequestProbe.shared.counts(offline.id).stops, 0)
    }

    func testDownloadWhilePreparingPlaybackDoesNotReplaceOrCancelSelection() async throws {
        let manager = try await manager()
        let selected = track(), offline = track()
        manager.select(selected, onReady: { _, _ in XCTFail("Held request cannot finish") })
        try await waitForStart(selected.id)
        let registered = expectation(description: "Offline request joins the independent pending queue")
        let subscription = manager.$downloadingIDs
            .first(where: { $0 == [selected.id, offline.id] })
            .sink { _ in registered.fulfill() }
        defer { subscription.cancel() }
        Task { _ = try? await manager.saveOfflineAudio(offline) }
        await fulfillment(of: [registered], timeout: 5)
        XCTAssertTrue(manager.isDownloading)
        XCTAssertEqual(manager.downloadingIDs, [selected.id, offline.id])
        XCTAssertEqual(DownloadRequestProbe.shared.counts(selected.id).starts, 1)
        XCTAssertEqual(DownloadRequestProbe.shared.counts(selected.id).stops, 0)
        manager.cancelOfflineAudio(offline)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(manager.downloadingIDs.contains(selected.id))
        XCTAssertEqual(DownloadRequestProbe.shared.counts(selected.id).stops, 0)
    }

    func testConfirmedPlaybackPrefetchesOnlyImmediateSuccessorAndPromotesSharedTransfer() async throws {
        let current = track(), next = track(), later = track()
        let manager = try await manager(cached: [current])
        manager.prefetch([next, later], playing: current.id)
        XCTAssertEqual(DownloadRequestProbe.shared.counts(next.id).starts, 0)
        var delivered = false
        manager.select(current, onReady: { _, _ in delivered = true })
        XCTAssertTrue(delivered)
        manager.prefetch([current, next, later], playing: current.id)
        try await waitForStart(next.id)
        XCTAssertEqual(DownloadRequestProbe.shared.counts(later.id).starts, 0)
        manager.prefetch([next, later], playing: current.id)
        manager.select(next, onReady: { _, _ in XCTFail("Held request cannot finish") })
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(DownloadRequestProbe.shared.counts(next.id).starts, 1)
        XCTAssertEqual(DownloadRequestProbe.shared.counts(next.id).stops, 0)
        XCTAssertEqual(DownloadRequestProbe.shared.counts(later.id).starts, 0)
    }

    func testCachedImmediateSuccessorDoesNotDownloadLaterQueueEntries() async throws {
        let current = track(), next = track(), later = track()
        let manager = try await manager(cached: [current, next])
        manager.select(current, onReady: { _, _ in })
        manager.prefetch([next, later], playing: current.id)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(DownloadRequestProbe.shared.counts(next.id).starts, 0)
        XCTAssertEqual(DownloadRequestProbe.shared.counts(later.id).starts, 0)
    }

    func testFailedPrefetchStaysSilentWithoutAnAutomaticRetryLoop() async throws {
        let current = track(), failed = track(), selected = track()
        let manager = try await manager(cached: [current])
        DownloadRequestProbe.shared.reject(failed.id)
        manager.select(current, onReady: { _, _ in })
        manager.prefetch([failed], playing: current.id)
        try await waitForStart(failed.id)
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertEqual(DownloadRequestProbe.shared.counts(failed.id).starts, 1)
        XCTAssertNil(manager.errorMessage)
        XCTAssertFalse(manager.isRetrying)
        manager.select(selected, onReady: { _, _ in XCTFail("Held request cannot finish") })
        try await waitForStart(selected.id)
        XCTAssertEqual(DownloadRequestProbe.shared.counts(failed.id).starts, 1)
    }

    func testPlaybackCompletionRemainsDisposableUntilExplicitOfflineSave() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let song = track()
        // Reconnection reads this metadata instead of inventing a remote cover.
        try JSONEncoder().encode([song.id: song]).write(to: folder.appendingPathComponent("pending.json"))
        let manager = try await manager(cacheFolder: folder)
        var endpoint = URLComponents(string: "https://fixture.test/download")!
        endpoint.queryItems = [URLQueryItem(name: "url", value: song.url.absoluteString)]
        let request = URLRequest(url: endpoint.url!)
        let transfer = Download(request: request)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [HeldAudioProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        // Exercise the real completion/cache path without relying on the
        // simulator's custom-URLProtocol support for download temporary files.
        await manager.download(transfer, didReconnectTask: session.downloadTask(with: request))
        let incoming = folder.appendingPathComponent("incoming.tmp")
        try Data(("RIFF" + String(repeating: "x", count: 32)).utf8).write(to: incoming)
        await manager.download(transfer, didFinishDownloadingTo: incoming)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(manager.cachedIDs.contains(song.id))
        XCTAssertFalse(TrackAudioCache(folder: folder).pinnedIDs.contains(song.id))
        _ = try await manager.saveOfflineAudio(song)
        for _ in 0..<100 {
            if TrackAudioCache(folder: folder).pinnedIDs.contains(song.id) { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("An explicit offline save must persist its pin")
    }
}
