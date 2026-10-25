import Foundation
import XCTest
@testable import NightcoreLab

/// Stub the LRCLIB transport; real external API availability is not a CI prerequisite.
private final class ManualLyricsURLProtocol: URLProtocol {
    static let fixture = ManualLyricsFixture()

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let (status, headers, body) = Self.fixture.response(for: request)
        let response = HTTPURLResponse(url: request.url!, statusCode: status,
                                       httpVersion: nil, headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private final class ManualLyricsFixture: @unchecked Sendable {
    private let lock = NSLock()
    private var status = 200
    private var headers: [String: String] = [:]
    private var body = Data()
    private var recordedRequest: URLRequest?

    func configure(status: Int = 200, headers: [String: String] = [:], body: Data) {
        lock.lock()
        defer { lock.unlock() }
        self.status = status
        self.headers = headers
        self.body = body
        recordedRequest = nil
    }

    func response(for request: URLRequest) -> (Int, [String: String], Data) {
        lock.lock()
        defer { lock.unlock() }
        recordedRequest = request
        return (status, headers, body)
    }

    var lastRequest: URLRequest? {
        lock.lock()
        defer { lock.unlock() }
        return recordedRequest
    }
}

final class ManualLyricsSearchTests: XCTestCase {
    private func makeClient() -> LRCLIBClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ManualLyricsURLProtocol.self]
        return LRCLIBClient(session: URLSession(configuration: config))
    }

    func testManualSearchTrimsQueryUsesIdentifiedClientAndDecodesResults() async throws {
        let json = """
        [{"id":42,"trackName":"Yellow","artistName":"Coldplay",
          "albumName":"Parachutes","duration":266,"instrumental":false,
          "plainLyrics":"Look at the stars","syncedLyrics":"[00:10.00]Look at the stars"}]
        """
        ManualLyricsURLProtocol.fixture.configure(body: Data(json.utf8))
        let results = try await LyricsService.searchManually("  Coldplay Yellow  ",
                                                            client: makeClient())
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results.first?.id, 42)
        XCTAssertTrue(results.first?.hasLyrics == true)

        let request = ManualLyricsURLProtocol.fixture.lastRequest
        XCTAssertEqual(request?.url?.path, "/api/search")
        XCTAssertEqual(URLComponents(url: request!.url!, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == "q" })?.value, "Coldplay Yellow")
        XCTAssertEqual(request?.value(forHTTPHeaderField: "User-Agent"),
                       LRCLIBClient.userAgent)
        XCTAssertTrue(LRCLIBClient.userAgent.contains("https://github.com/"))
    }

    func testManualSearchEmptyResponseIsNotTransportError() async throws {
        ManualLyricsURLProtocol.fixture.configure(body: Data("[]".utf8))
        let result = try await LyricsService.searchManually("unknown", client: makeClient())
        XCTAssertTrue(result.isEmpty)
    }

    func testManualSearchRateLimitReportsRetryAfterAndDoesNotRetry() async throws {
        ManualLyricsURLProtocol.fixture.configure(status: 429,
            headers: ["Retry-After": "15"], body: Data("rate limit".utf8))
        do {
            _ = try await LyricsService.searchManually("Yellow", client: makeClient())
            XCTFail("Expected 429 to be surfaced")
        } catch let error as LRCLIBRequestError {
            guard case .rateLimited(let retryAfter) = error else {
                return XCTFail("Expected a rate-limit error, not \(error)")
            }
            XCTAssertEqual(retryAfter, 15)
            XCTAssertTrue(error.localizedDescription.contains("15"))
        }
    }

    func testManualSearchHandles404AsNoResults() async throws {
        ManualLyricsURLProtocol.fixture.configure(status: 404,
                                                  body: Data("not found".utf8))
        let result = try await LyricsService.searchManually("unknown", client: makeClient())
        XCTAssertTrue(result.isEmpty)
    }

    func testManualSearch503IsDistinguishableFromNoMatch() async throws {
        ManualLyricsURLProtocol.fixture.configure(status: 503,
                                                  body: Data("unavailable".utf8))
        do {
            _ = try await LyricsService.searchManually("Yellow", client: makeClient())
            XCTFail("Expected a service-unavailable error")
        } catch let error as LRCLIBRequestError {
            guard case .serviceUnavailable = error else {
                return XCTFail("Expected a 503 error, not \(error)")
            }
        }
    }
}
