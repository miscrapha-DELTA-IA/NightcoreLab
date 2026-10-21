import XCTest
@testable import NightcoreLab

final class CloudStemWorkerTests: XCTestCase {
    let space = URL(string: "https://raphael-deltaia-gnarly-free-stems.hf.space")!
    let sourceHash = String(repeating: "a", count: 64)

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
}
