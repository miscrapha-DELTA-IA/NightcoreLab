import Foundation
import XCTest
@testable import NightcoreLab

/// Deterministic in-process HTTP stub; never calls the live Render backend.
private final class OmniboxStubServer {
    struct Reply {
        let status: Int
        let data: Data
        let delay: TimeInterval
        // Test-only ordering gate: avoids relying on simulator wall-clock delays.
        let gate: DispatchSemaphore?

        init(_ status: Int = 200, _ data: Data, delay: TimeInterval = 0,
             gate: DispatchSemaphore? = nil) {
            self.status = status
            self.data = data
            self.delay = delay
            self.gate = gate
        }
    }

    static let shared = OmniboxStubServer()
    private let lock = NSLock()
    private var replies: [String: Reply] = [:]

    func set(_ replies: [String: Reply]) {
        lock.lock()
        self.replies = replies
        lock.unlock()
    }

    func get(_ request: URLRequest) -> Reply {
        let url = request.url!
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == "q" })?.value ?? ""
        let key = "\(url.path)|\(query)"
        lock.lock()
        let result = replies[key] ?? Reply(404, Data())
        lock.unlock()
        return result
    }
}

private final class OmniboxStubProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let reply = OmniboxStubServer.shared.get(request)
        // Asynchronous delivery makes out-of-order responses reproducible.
        DispatchQueue.global().asyncAfter(deadline: .now() + reply.delay) { [weak self] in
            // Only the explicitly gated test waits, on a background queue.
            // The timeout prevents an XCTest failure from hanging the worker.
            if let gate = reply.gate {
                _ = gate.wait(timeout: .now() + 15)
            }
            guard let self, let url = self.request.url,
                  let response = HTTPURLResponse(url: url, statusCode: reply.status,
                                                 httpVersion: nil, headerFields: nil) else { return }
            self.client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            self.client?.urlProtocol(self, didLoad: reply.data)
            self.client?.urlProtocolDidFinishLoading(self)
        }
    }

    override func stopLoading() {}
}

@MainActor
final class OmniboxRobustnessTests: XCTestCase {
    private func client(now: @escaping () -> Date = Date.init) -> OmniboxEngine {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [OmniboxStubProtocol.self]
        return OmniboxEngine(baseURL: URL(string: "https://nightcore.test/")!,
                             session: URLSession(configuration: configuration),
                             debounce: .zero, now: now)
    }

    private func hit(_ id: String, name: String) -> TrackHit {
        TrackHit(id: id, title: name, artist: "Artist", album: nil,
                 duration: 180, thumb: nil, isSong: true, explicit: false)
    }

    private func hits(_ values: [TrackHit]) throws -> Data {
        try JSONEncoder().encode(values)
    }

    private func wait(_ state: @escaping () -> Bool, attempts: Int = 100,
                      file: StaticString = #filePath, line: UInt = #line) async {
        for _ in 0..<attempts {
            if state() { return }
            try? await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("Timed out waiting for Omnibox response", file: file, line: line)
    }

    func testCacheFreshnessAndExpiredEntries() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        XCTAssertEqual(OmniboxCachePolicy.freshness(savedAt: now, now: now), .fresh)
        XCTAssertEqual(OmniboxCachePolicy.freshness(
            savedAt: now.addingTimeInterval(-301), now: now), .stale)
        XCTAssertEqual(OmniboxCachePolicy.freshness(
            savedAt: now.addingTimeInterval(-86_401), now: now), .expired)
        XCTAssertEqual(OmniboxCachePolicy.freshness(
            savedAt: now.addingTimeInterval(20), now: now), .expired)
    }

    func testTypingStaysOfflineUntilExplicitSearch() async throws {
        OmniboxStubServer.shared.set([
            "/v1/search|song": .init(200, try hits([hit("ccccccccccc", name: "Song")])),
            "/v1/suggest|song": .init(200, Data("[\"song\"]".utf8))
        ])
        let engine = client()
        engine.queryChanged("so")
        engine.queryChanged("son")
        engine.queryChanged("song")
        try await Task.sleep(for: .milliseconds(180))
        XCTAssertEqual(engine.loadState, .local)
        XCTAssertFalse(engine.isSearching)
        XCTAssertFalse(engine.hasSearched)
        XCTAssertTrue(engine.results.isEmpty)
        engine.submit("song")
        await wait { engine.loadState == .ready && !engine.isSearching }
        XCTAssertEqual(engine.results.first?.id, "ccccccccccc")
    }

    func testNewQueryNeverShowsResultsFromPreviousQuery() async throws {
        OmniboxStubServer.shared.set([
            "/v1/search|alpha": .init(200, try hits([hit("aaaaaaaaaaa", name: "Alpha")]), delay: 0.5),
            "/v1/suggest|alpha": .init(200, Data("[\"Alpha\"]".utf8), delay: 0.5),
            "/v1/search|beta": .init(200, try hits([hit("bbbbbbbbbbb", name: "Beta")]), delay: 0.01),
            "/v1/suggest|beta": .init(200, Data("[\"Beta\"]".utf8), delay: 0.01)
        ])
        let engine = client()
        engine.submit("alpha")
        try await Task.sleep(for: .milliseconds(80))
        engine.submit("beta")
        XCTAssertFalse(engine.results.contains { $0.id == "aaaaaaaaaaa" })
        await wait { engine.loadState == .ready && !engine.isSearching }
        XCTAssertEqual(engine.results.first?.id, "bbbbbbbbbbb")
        try await Task.sleep(for: .milliseconds(600))
        XCTAssertEqual(engine.results.first?.id, "bbbbbbbbbbb")
        XCTAssertEqual(engine.suggestions, ["Beta"])
    }

    func testPartialResultsArriveBeforeSuggestionsThenBecomeReady() async throws {
        // The suggestion cannot beat the results, even on a heavily loaded CI
        // simulator. This verifies the intermediate state without a timing race.
        let suggestionGate = DispatchSemaphore(value: 0)
        defer { suggestionGate.signal() }
        OmniboxStubServer.shared.set([
            "/v1/search|track": .init(200, try hits([hit("aaaaaaaaaaa", name: "Track")])),
            "/v1/suggest|track": .init(200, Data("[\"Track suggestion\"]".utf8),
                                      gate: suggestionGate)
        ])
        let engine = client()
        engine.submit("track")
        await wait({ engine.loadState == .partial &&
                     engine.results.first?.id == "aaaaaaaaaaa" }, attempts: 300)
        XCTAssertTrue(engine.isSearching)
        suggestionGate.signal()
        await wait({ engine.loadState == .ready && !engine.isSearching }, attempts: 300)
        XCTAssertEqual(engine.suggestions, ["Track suggestion"])
    }

    func testFailedSuggestionKeepsSearchResultsAsPartialSuccess() async throws {
        OmniboxStubServer.shared.set([
            "/v1/search|song": .init(200, try hits([hit("ccccccccccc", name: "Song")])),
            "/v1/suggest|song": .init(503, Data())
        ])
        let engine = client()
        engine.submit("song")
        await wait { engine.hasSearched && !engine.isSearching }
        XCTAssertEqual(engine.results.first?.id, "ccccccccccc")
        XCTAssertTrue(engine.lastRequestFailed)
        XCTAssertEqual(engine.loadState, .partial)
    }

    func testStaleCacheSurvivesFailedRefreshAndCanBeReused() async throws {
        var date = Date(timeIntervalSince1970: 1_000_000)
        OmniboxStubServer.shared.set([
            "/v1/search|song": .init(200, try hits([hit("ccccccccccc", name: "Song")])),
            "/v1/suggest|song": .init(200, Data("[\"song\"]".utf8))
        ])
        let engine = client(now: { date })
        engine.submit("song")
        await wait { engine.loadState == .ready && !engine.isSearching }
        XCTAssertEqual(engine.results.first?.id, "ccccccccccc")

        date.addTimeInterval(360)
        OmniboxStubServer.shared.set([
            "/v1/search|song": .init(500, Data()),
            "/v1/suggest|song": .init(500, Data())
        ])
        engine.submit("song")
        XCTAssertTrue(engine.isShowingStaleCache)
        XCTAssertEqual(engine.results.first?.id, "ccccccccccc")
        await wait { engine.hasSearched && !engine.isSearching }
        XCTAssertEqual(engine.results.first?.id, "ccccccccccc")
        XCTAssertEqual(engine.loadState, .partial)
        XCTAssertTrue(engine.lastRequestFailed)
        XCTAssertTrue(engine.isShowingStaleCache)
    }

    func testServerChangeInvalidatesScopedCacheAndPendingRequests() async throws {
        OmniboxStubServer.shared.set([
            "/v1/search|song": .init(200, try hits([hit("ccccccccccc", name: "Song")]), delay: 0.25),
            "/v1/suggest|song": .init(200, Data("[\"song\"]".utf8), delay: 0.25)
        ])
        let engine = client()
        engine.submit("song")
        try await Task.sleep(for: .milliseconds(50))
        engine.useServer(URL(string: "https://another-server.test/")!)
        XCTAssertEqual(engine.loadState, .idle)
        XCTAssertTrue(engine.results.isEmpty)
        try await Task.sleep(for: .milliseconds(350))
        XCTAssertTrue(engine.results.isEmpty)
        XCTAssertTrue(engine.suggestions.isEmpty)
    }
}
