import Foundation
import XCTest
@testable import NightcoreLab

private final class DownloadRequestProbe: @unchecked Sendable {
    static let shared = DownloadRequestProbe()
    private let lock = NSLock()
    private var starts: [String: Int] = [:]
    private var stops: [String: Int] = [:]
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
}

/// Hold transfers open without network or audio, observing actual cancellation.
private final class HeldAudioProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() { DownloadRequestProbe.shared.record(request, stopped: false) }
    override func stopLoading() { DownloadRequestProbe.shared.record(request, stopped: true) }
}

@MainActor
final class DownloadIndependenceTests: XCTestCase {
    private func manager() throws -> AudioDownloadManager {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [HeldAudioProtocol.self]
        let manager = AudioDownloadManager(configuration: configuration, cacheFolder: folder)
        addTeardownBlock { await MainActor.run { manager.cancel() } }
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
        let manager = try manager()
        let offline = track(), selected = track()
        manager.downloadForOffline(offline)
        try await waitForStart(offline.id)
        manager.select(selected, onReady: { _, _ in XCTFail("Held request cannot finish") })
        try await waitForStart(selected.id)
        XCTAssertEqual(Set(manager.pendingTracks.map(\.id)), [offline.id, selected.id])
        XCTAssertEqual(DownloadRequestProbe.shared.counts(offline.id).stops, 0)
        manager.select(offline, onReady: { _, _ in XCTFail("Held request cannot finish") })
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(DownloadRequestProbe.shared.counts(offline.id).starts, 1)
        XCTAssertEqual(DownloadRequestProbe.shared.counts(selected.id).stops, 0)
        manager.cancelPlaybackSelection()
        XCTAssertEqual(DownloadRequestProbe.shared.counts(offline.id).stops, 0)
    }

    func testDownloadWhilePreparingPlaybackDoesNotReplaceOrCancelSelection() async throws {
        let manager = try manager()
        let selected = track(), offline = track()
        manager.select(selected, onReady: { _, _ in XCTFail("Held request cannot finish") })
        try await waitForStart(selected.id)
        manager.downloadForOffline(offline)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(manager.isDownloading)
        XCTAssertEqual(Set(manager.pendingTracks.map(\.id)), [selected.id, offline.id])
        XCTAssertEqual(DownloadRequestProbe.shared.counts(selected.id).starts, 1)
        XCTAssertEqual(DownloadRequestProbe.shared.counts(selected.id).stops, 0)
        manager.cancelDownload(offline)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(manager.pendingTracks.contains { $0.id == selected.id })
        XCTAssertEqual(DownloadRequestProbe.shared.counts(selected.id).stops, 0)
    }
}
