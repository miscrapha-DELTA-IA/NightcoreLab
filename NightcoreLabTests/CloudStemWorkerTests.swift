import XCTest
@testable import NightcoreLab

final class CloudStemWorkerTests: XCTestCase {
    let space = URL(string: "https://raphael-deltaia-gnarly-free-stems.hf.space")!
    let sourceHash = String(repeating: "a", count: 64)

    func testGradioUploadAcceptsOnlySafeAudioFilePaths() throws {
        let path = "/tmp/gradio/sha256/source.m4a"
        let legacy = try JSONSerialization.data(withJSONObject: [path])
        let dictionary = try JSONSerialization.data(withJSONObject: [
            ["path": path, "orig_name": "source.m4a", "meta": ["_type": "gradio.FileData"]]
        ])
        XCTAssertEqual(try CloudStemWorker.uploadedAudioPath(legacy), path)
        XCTAssertEqual(try CloudStemWorker.uploadedAudioPath(dictionary), path)
        for response in [
            Data("<html>temporary error</html>".utf8),
            Data("{\"detail\":\"unavailable\"}".utf8),
            Data("[]".utf8),
            try JSONSerialization.data(withJSONObject: ["https://external.invalid/source.m4a"]),
            try JSONSerialization.data(withJSONObject: ["/tmp/../secrets/source.m4a"]),
            try JSONSerialization.data(withJSONObject: ["/tmp/gradio/source.wav"]),
        ] {
            XCTAssertThrowsError(try CloudStemWorker.uploadedAudioPath(response)) { error in
                XCTAssertTrue(error is CloudStemWorker.Failure,
                              "Must return a user-facing provider error instead of NSCocoaErrorDomain")
            }
        }
    }

    func testGradioCompletionAcceptsArrayAndWrappedQueueEnvelopes() throws {
        let community = CloudStemWorker.communityURL
        let files = ["01_vocals.wav", "02_drums.wav", "03_bass.wav", "04_other.wav"].map {
            ["orig_name": $0, "url": community.absoluteString + "/gradio_api/file=/tmp/" + $0]
        }
        let values: [Any] = ["Ready", files, NSNull(), "unused HTML"]
        let raw = try JSONSerialization.data(withJSONObject: values)
        let wrapped = try JSONSerialization.data(withJSONObject: ["data": values])
        let nested = try JSONSerialization.data(withJSONObject: ["output": ["data": values]])
        for input in [raw, wrapped, nested] {
            XCTAssertEqual(try CloudStemWorker.communityCompletion(input, space: community), 
                           try CloudStemWorker.communityCompletion(raw, space: community))
        }
        for invalid in [Data("null".utf8), Data("<html>Queue blocked</html>".utf8),
                        Data("{\"output\":{}}".utf8)] {
            XCTAssertThrowsError(try CloudStemWorker.normalizedResult(invalid)) { error in
                XCTAssertTrue(error is CloudStemWorker.Failure)
            }
        }
    }

    func testEscapedGradioJSONAndSSECompletionAreReadable() throws {
        let space = CloudStemWorker.communityURL
        let files = ["01_vocals.wav", "02_drums.wav", "03_bass.wav", "04_other.wav"].map {
            ["orig_name": $0, "url": space.absoluteString + "/gradio_api/file=/tmp/" + $0]
        }
        let result: [Any] = ["Ready", files, NSNull(), "unused HTML"]
        let plain = try JSONSerialization.data(withJSONObject: result)
        let text = try XCTUnwrap(String(data: plain, encoding: .utf8))
        let encoded = try JSONSerialization.data(withJSONObject: text, options: [.fragmentsAllowed])
        XCTAssertEqual(try CloudStemWorker.communityCompletion(encoded, space: space),
                       try CloudStemWorker.communityCompletion(plain, space: space))

        var events = CloudStemWorker.SSEEvents()
        XCTAssertNil(try events.feed("event: complete"))
        XCTAssertNil(try events.feed("data: " + text))
        guard case .complete(let response)? = try events.feed("") else {
            return XCTFail("Expected a completed SSE result")
        }
        XCTAssertEqual(try CloudStemWorker.communityCompletion(response, space: space),
                       try CloudStemWorker.communityCompletion(plain, space: space))
    }

    func testBadCachedResultCanBeRequeriedWithoutChangingSavedIdentifiers() throws {
        let space = CloudStemWorker.communityURL
        let malformed = Data("<html>temporarily unavailable</html>".utf8)
        XCTAssertTrue(CloudStemWorker.cachedResultRequiresReadOnlyRefresh(
            malformed, community: true, space: space, sourceHash: sourceHash))
        let absent = Data("null".utf8)
        XCTAssertTrue(CloudStemWorker.cachedResultRequiresReadOnlyRefresh(
            absent, community: true, space: space, sourceHash: sourceHash))
        let files = ["01_vocals.wav", "02_drums.wav", "03_bass.wav", "04_other.wav"].map {
            ["orig_name": $0, "url": space.absoluteString + "/gradio_api/file=/tmp/" + $0]
        }
        let valid = try JSONSerialization.data(
            withJSONObject: ["Ready", files, NSNull(), "HTML"] as [Any])
        XCTAssertFalse(CloudStemWorker.cachedResultRequiresReadOnlyRefresh(
            valid, community: true, space: space, sourceHash: sourceHash))
        // The pending admission, eventID, source audio and partial downloads
        // are not modified by validation. Production only issues GET on resume.
    }

    func testOnlyExactHTTPSFileOriginIsAccepted() {
        XCTAssertTrue(CloudStemWorker.permittedSpace(space))
        XCTAssertTrue(CloudStemWorker.permittedDownload(space.appendingPathComponent("gradio_api/file=/tmp/test.wav"), space: space))
        for value in ["http://raphael-deltaia-gnarly-free-stems.hf.space/gradio_api/file=x",
                      "https://attacker.test/gradio_api/file=x", "https://raphael-deltaia-gnarly-free-stems.hf.space.attacker.test/gradio_api/file=x",
                      "https://raphael-deltaia-gnarly-free-stems.hf.space/config"] {
            XCTAssertFalse(CloudStemWorker.permittedDownload(URL(string: value)!, space: space))
        }
        XCTAssertFalse(CloudStemWorker.permittedSpace(URL(string: "https://user:pass@test.hf.space")!))
    }

    func testGradioCompletionBindsFourStemsToOriginalAndRejectsForeignDownloads() throws {
        let manifest: [String: Any] = ["model": "htdemucs", "source_hash": sourceHash,
            "frames": 44_100, "sample_rate": 44_100,
            "sha256": ["vocals": sourceHash, "other": sourceHash, "drums": sourceHash, "bass": sourceHash]]
        var values: [Any] = (0..<4).map { ["url": space.absoluteString + "/gradio_api/file=/tmp/\($0).wav"] }
        values.append(manifest)
        let data = try JSONSerialization.data(withJSONObject: values)
        let result = try CloudStemWorker.completion(data, space: space, sourceHash: sourceHash)
        XCTAssertEqual(result.0.count, 4)
        XCTAssertEqual(result.1.frames, 44_100)
        XCTAssertThrowsError(try CloudStemWorker.completion(data, space: space, sourceHash: String(repeating: "b", count: 64)))
        values[0] = ["url": "https://attacker.test/file.wav"]
        XCTAssertThrowsError(try CloudStemWorker.completion(JSONSerialization.data(withJSONObject: values), space: space, sourceHash: sourceHash))
    }

    func testPublicRoformerContractMapsNamedFilesAndRejectsOtherOriginsOrDuplicates() throws {
        let community = CloudStemWorker.communityURL
        let labels = ["01_vocals.wav", "02_drums.wav", "03_bass.wav", "04_other.wav"]
        var files: [[String: Any]] = labels.map {
            ["orig_name": $0, "url": community.absoluteString + "/gradio_api/file=/tmp/gradio/test/" + $0]
        }
        func response() throws -> Data {
            try JSONSerialization.data(withJSONObject: ["Ready", files, NSNull(), "unused HTML"] as [Any])
        }
        let urls = try CloudStemWorker.communityCompletion(response(), space: community)
        XCTAssertTrue(urls[0].lastPathComponent.contains("vocals"))
        XCTAssertTrue(urls[1].lastPathComponent.contains("other"))
        XCTAssertTrue(urls[2].lastPathComponent.contains("drums"))
        XCTAssertTrue(urls[3].lastPathComponent.contains("bass"))
        XCTAssertThrowsError(try CloudStemWorker.communityCompletion(response(), space: space))
        files[0]["url"] = "https://attacker.test/gradio_api/file=test.wav"
        XCTAssertThrowsError(try CloudStemWorker.communityCompletion(response(), space: community))
        files[0] = files[1]
        XCTAssertThrowsError(try CloudStemWorker.communityCompletion(response(), space: community))
    }
    func testGPUPreflightDistinguishesExactHTDemucsFromCommunityRoformer() throws {
        func status(_ provider: String, _ model: String, ready: Bool? = true,
                    freeOnly: Bool = true, enabled: Bool = true) throws -> CloudStemWorker.Status {
            var dictionary: [String: Any] = [
                "enabled": enabled, "free_only": freeOnly, "provider": provider,
                "model": model, "requires_beta_code": false
            ]
            if let ready { dictionary["provider_available"] = ready }
            return try JSONDecoder().decode(CloudStemWorker.Status.self,
                                            from: JSONSerialization.data(withJSONObject: dictionary))
        }
        let localEquivalent = try status("owned_htdemucs", "htdemucs", ready: nil)
        XCTAssertTrue(localEquivalent.isReady)
        XCTAssertFalse(localEquivalent.usesDifferentModel)
        XCTAssertEqual(localEquivalent.modelTitle, "HTDemucs (GPU)")
        let community = try status("community_bs_roformer", CloudStemWorker.communityModel)
        XCTAssertTrue(community.isReady)
        XCTAssertTrue(community.usesDifferentModel)
        XCTAssertTrue(community.modelTitle.contains("BS-Roformer"))
        XCTAssertFalse(try status("community_bs_roformer", "htdemucs").isReady)
        XCTAssertFalse(try status("owned_htdemucs", CloudStemWorker.communityModel).isReady)
        XCTAssertFalse(try status("community_bs_roformer", CloudStemWorker.communityModel, ready: false).isReady)
        XCTAssertFalse(try status("community_bs_roformer", CloudStemWorker.communityModel, freeOnly: false).isReady)
        XCTAssertFalse(try status("community_bs_roformer", CloudStemWorker.communityModel, enabled: false).isReady)
    }

    func testStatusPreflightUsesOnlyReadOnlyGETAndNoHuggingFaceUpload() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [CloudStatusOnlyProtocol.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let status = try await CloudStemWorker.checkStatus(
            serverURL: URL(string: "https://nightcorelab.onrender.com")!,
            requestSession: session)
        XCTAssertTrue(status.isReady)
        XCTAssertTrue(status.usesDifferentModel)
        XCTAssertEqual(CloudStatusOnlyProtocol.receivedMethod, "GET")
        XCTAssertEqual(CloudStatusOnlyProtocol.receivedPath, "/v1/stems/cloud")
    }

}

private final class CloudStatusOnlyProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    private static var lastMethod = ""
    private static var lastPath = ""
    static var receivedMethod: String {
        lock.lock(); defer { lock.unlock() }; return lastMethod
    }
    static var receivedPath: String {
        lock.lock(); defer { lock.unlock() }; return lastPath
    }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock()
        Self.lastMethod = request.httpMethod ?? ""
        Self.lastPath = request.url?.path ?? ""
        Self.lock.unlock()
        let data = Data("""
            {"enabled":true,"free_only":true,"provider_available":true,
             "provider":"community_bs_roformer","model":"bs-roformer-musdb18hq",
             "requires_beta_code":false}
            """.utf8)
        let reply = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
                                    headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: reply, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
