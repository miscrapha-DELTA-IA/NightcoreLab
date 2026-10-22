import AVFoundation
import XCTest
@testable import NightcoreLab

final class CloudStemRecoveryTests: XCTestCase {
    func testTransferCommitsResponseAndReopenedCoordinatorReusesItWithoutNetwork() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        RecoveryRequests.reset()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [RecoveryRequests.self]
        let transfer = CloudStemTransfer(configuration: config, directory: directory)
        let url = URL(string: "https://backend.invalid/v1/stems/cloud/ticket")!
        let first = try await withThrowingTaskGroup(of: URL.self) { group in
            group.addTask { try await transfer.download(url, key: "saved-response") }
            group.addTask {
                try await Task.sleep(for: .seconds(8))
                throw URLError(.timedOut)
            }
            defer { group.cancelAll() }
            return try await group.next()!
        }
        let data = try Data(contentsOf: first)
        XCTAssertFalse(data.isEmpty)
        XCTAssertEqual(RecoveryRequests.count(url.path), 1)
        let reopened = CloudStemTransfer(configuration: config, directory: directory)
        let restored = try await reopened.download(url, key: "saved-response")
        XCTAssertEqual(try Data(contentsOf: restored), data)
        XCTAssertEqual(RecoveryRequests.count(url.path), 1)
    }

    func testNetworkDropAndPartialDownloadsResumeSameGPUJobWithoutAnotherAdmission() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2)!
        func wav(_ name: String, value: Float) throws -> URL {
            let url = directory.appendingPathComponent(name)
            try autoreleasepool {
                let file = try AVAudioFile(forWriting: url, settings: format.settings)
                let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4_410)!
                buffer.frameLength = 4_410
                for channel in 0..<2 { buffer.floatChannelData![channel].update(repeating: value, count: 4_410) }
                try file.write(from: buffer)
            }
            return url
        }
        let source = try wav("source.wav", value: 0.3)
        let names = ["01_vocals.wav", "02_drums.wav", "03_bass.wav", "04_other.wav"]
        var fixtures: [String: URL] = [:]
        for (index, name) in names.enumerated() { fixtures[name] = try wav(name, value: Float(index + 1) * 0.02) }
        let files = names.map { ["orig_name": $0, "url": CloudStemWorker.communityURL.absoluteString + "/gradio_api/file=/tmp/" + $0] }
        let payload = try JSONSerialization.data(withJSONObject: ["Ready", files, NSNull(), "unused HTML"] as [Any])
        let sse = directory.appendingPathComponent("events.txt")
        try ("event: heartbeat\ndata: null\n\nevent: complete\ndata: " + String(decoding: payload, as: UTF8.self) + "\n\n")
            .write(to: sse, atomically: true, encoding: .utf8)
        let plan = RecoveryDownloads(directory: directory, sse: sse, fixtures: fixtures)
        RecoveryRequests.reset(dropAdmissionResponse: true)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [RecoveryRequests.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        func prepare() async throws -> StemAsset {
            try await CloudStemWorker.prepare(source: source, betaCode: "",
                cacheFolder: directory.appendingPathComponent("cache"),
                workFolder: directory.appendingPathComponent("work"),
                serverURL: URL(string: "https://backend.invalid"), requestSession: session, hfToken: "",
                transfer: { url, key in try await plan.fetch(url, key: key) }, progress: { _, _ in })
        }
        for _ in 0..<3 {
            do { _ = try await prepare(); XCTFail("Fixture interrupts admission, SSE and one stem") }
            catch is URLError { }
        }
        let result = try await prepare()
        XCTAssertEqual(result.source, .roformer)
        XCTAssertEqual(try NeuralStemWorker.validate(result), 4_410)
        XCTAssertEqual(RecoveryRequests.count("/v1/stems/cloud/ticket"), 2)
        XCTAssertEqual(Set(RecoveryRequests.admissionKeys).count, 1, "A lost POST reply must reuse the same admission key")
        XCTAssertNotNil(RecoveryRequests.admissionKeys.first.flatMap(UUID.init(uuidString:)))
        XCTAssertEqual(RecoveryRequests.count("/gradio_api/upload"), 1)
        XCTAssertEqual(RecoveryRequests.count("/gradio_api/call/separate"), 1)
        let peak = await plan.maximumActiveFiles
        XCTAssertEqual(peak, 4, "Four bounded file transfers must overlap; a failure preserves siblings")
        let counts = await plan.counts
        XCTAssertEqual(counts["events"], 2)
        XCTAssertEqual(counts["01_vocals.wav"], 1)
        XCTAssertEqual(counts["04_other.wav"], 1)
        XCTAssertEqual(counts["02_drums.wav"], 1)
        XCTAssertEqual(counts["03_bass.wav"], 2)
        _ = try await prepare()
        let afterCache = await plan.counts
        XCTAssertEqual(afterCache, counts, "Offline completed cache must not touch the provider again")
    }

    func testSavedEventAndPayloadSurviveRelaunchAndInterruptedStreamIsNotQuotaError() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        var pending = CloudStemWorker.Pending()
        pending.eventID = String(repeating: "a", count: 32)
        pending.submitting = true
        pending.payload = Data("[1,2,3]".utf8)
        try pending.save(to: file)
        let restored = try JSONDecoder().decode(CloudStemWorker.Pending.self, from: Data(contentsOf: file))
        XCTAssertEqual(restored.eventID, pending.eventID)
        XCTAssertEqual(restored.payload, pending.payload)
        XCTAssertThrowsError(try CloudStemWorker.streamPayload(Data("event: heartbeat\ndata: null\n".utf8))) {
            XCTAssertFalse($0 is CloudStemWorker.ProviderFailure)
        }
        XCTAssertThrowsError(try CloudStemWorker.streamPayload(Data("event: error\ndata: null\n".utf8))) {
            XCTAssertTrue($0 is CloudStemWorker.ProviderFailure)
        }
    }
}

private actor RecoveryDownloads {
    let directory: URL
    let sse: URL
    let fixtures: [String: URL]
    var counts: [String: Int] = [:]
    private var activeFiles = 0
    var maximumActiveFiles = 0
    init(directory: URL, sse: URL, fixtures: [String: URL]) {
        self.directory = directory; self.sse = sse; self.fixtures = fixtures
    }
    func fetch(_ url: URL, key: String) async throws -> URL {
        let event = url.path.contains("/call/")
        let name = event ? "events" : url.lastPathComponent
        counts[name, default: 0] += 1
        if !event {
            activeFiles += 1; maximumActiveFiles = max(maximumActiveFiles, activeFiles)
            do { try await Task.sleep(for: .milliseconds(20)) }
            catch { activeFiles -= 1; throw error }
            activeFiles -= 1
        }
        if (event || name == "03_bass.wav") && counts[name] == 1 { throw URLError(.networkConnectionLost) }
        let copy = directory.appendingPathComponent(UUID().uuidString)
        guard let source = event ? sse : fixtures[name] else { throw URLError(.fileDoesNotExist) }
        try FileManager.default.copyItem(at: source, to: copy)
        return copy
    }
}

private final class RecoveryRequests: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    private static var counts: [String: Int] = [:]
    private static var keys: [String] = []
    private static var dropAdmissionResponse = false
    static var admissionKeys: [String] { lock.lock(); defer { lock.unlock() }; return keys }
    static func reset(dropAdmissionResponse: Bool = false) { lock.lock(); counts = [:]; keys = []; Self.dropAdmissionResponse = dropAdmissionResponse; lock.unlock() }
    static func count(_ path: String) -> Int { lock.lock(); defer { lock.unlock() }; return counts[path, default: 0] }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let url = request.url!
        Self.lock.lock(); Self.counts[url.path, default: 0] += 1; Self.lock.unlock()
        if url.path == "/v1/stems/cloud/ticket", let key = request.value(forHTTPHeaderField: "Idempotency-Key") {
            Self.lock.lock(); Self.keys.append(key)
            let drop = Self.dropAdmissionResponse; Self.dropAdmissionResponse = false
            Self.lock.unlock()
            if drop { client?.urlProtocol(self, didFailWithError: URLError(.networkConnectionLost)); return }
        }
        let object: Any
        switch url.path {
        case "/v1/stems/cloud/ticket": object = ["ticket": "public", "space_url": CloudStemWorker.communityURL.absoluteString,
            "model": CloudStemWorker.communityModel, "provider": "community_bs_roformer"]
        case "/gradio_api/upload": object = ["/tmp/source.m4a"]
        case "/gradio_api/call/separate": object = ["event_id": String(repeating: "a", count: 32)]
        default: client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL)); return
        }
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: try! JSONSerialization.data(withJSONObject: object))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
