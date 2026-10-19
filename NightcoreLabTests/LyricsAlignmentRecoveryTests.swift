import Foundation
import XCTest
@testable import NightcoreLab

final class LyricsAlignmentRecoveryTests: XCTestCase {
    func testOldCacheWithoutGeneratedLyricsStillDecodes() throws {
        let old = #"{"selected":null,"score":0,"needsReview":false,"pinned":false,"alternatives":[],"savedAt":0}"#
        let choice = try JSONDecoder().decode(CachedLyricsChoice.self, from: Data(old.utf8))
        XCTAssertNil(choice.generatedLRC)
        XCTAssertNil(choice.offlinePinned)
    }

    func testAlignmentRequestAndResponse() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [AlignmentStub.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let lrc = try await LyricsAlignmentClient.align(videoID: "abcdefghijk", lyrics: "Olá",
            baseURL: "https://example.org/api", session: session)
        XCTAssertTrue(lrc.contains("Olá"))
    }

    func testUnavailableAlignmentHasAnActionableError() async {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [AlignmentStub.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        do {
            _ = try await LyricsAlignmentClient.align(videoID: "abcdefghijk", lyrics: "Olá",
                baseURL: "https://example.org/missing", session: session)
            XCTFail("A 404 must not be accepted as aligned lyrics")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("OpenAI"))
        }
    }

    @MainActor
    func testLateAlignmentCannotReplaceAnotherTrack() async {
        let store = LyricsStore()
        store.beginLoading(trackID: "current")
        await store.installAlignedLyrics("[00:01.00] <00:01.00> Olá <00:02.00>", trackID: "previous")
        XCTAssertEqual(store.trackID, "current")
        XCTAssertTrue(store.lines.isEmpty)
    }

    @MainActor
    func testAlignmentFailurePreservesAvailableLyrics() async {
        let store = LyricsStore()
        store.beginLoading(trackID: "current")
        await store.installAlignedLyrics("[00:01.00] <00:01.00> Olá <00:02.00>", trackID: "current")
        let lines = store.lines
        XCTAssertFalse(lines.isEmpty)
        store.setAlignmentNotice("Servidor ocupado", trackID: "current")
        XCTAssertEqual(store.lines, lines)
        XCTAssertEqual(store.status, .ready)
    }

    func testUpstreamLimitExplainsWhyOfflineTracksStillWork() {
        let message = DownloadFailureMessage.describe(URLError(.badServerResponse), status: 429,
                                                     upstreamCode: "upstream_rate_limited")
        XCTAssertTrue(message.contains("YouTube"))
        XCTAssertTrue(message.contains("já baixadas"))
    }
}

private final class AlignmentStub: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertTrue(request.url!.path.hasSuffix("/align-lyrics"))
        let missing = request.url!.path.contains("missing")
        let response = HTTPURLResponse(url: request.url!, statusCode: missing ? 404 : 200,
                                       httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        let body = missing ? #"{"detail":"Not Found"}"# : #"{"lrc":"[00:01.00] <00:01.00> Olá <00:02.00>"}"#
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
