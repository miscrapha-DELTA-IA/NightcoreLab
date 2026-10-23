import AVFoundation
import XCTest
@testable import NightcoreLab

final class Stage42CatalogAndDownloadTests: XCTestCase {
    func testNativeStreamIsStoredByteForByteWithoutAACConversion() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let input = root.appendingPathComponent("download.tmp")
        // ISO base media header intentionally cannot be decoded by AVAudioFile.
        // Cache transport preserves the container; playback owns decoding errors.
        let original = Data([0, 0, 0, 24] + Array("ftypM4A ".utf8) + Array(repeating: 0, count: 64))
        try original.write(to: input)
        var cache = TrackAudioCache(folder: root.appendingPathComponent("cache"))
        let url = try cache.store(Track(id: "abcdefghijk", title: "Song", thumbnailURL: nil), from: input)
        XCTAssertEqual(try Data(contentsOf: url), original)
        XCTAssertEqual(url.pathExtension, "m4a")
    }

    func testNativeContainersAndServerErrorBody() throws {
        let input = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: input) }
        for (header, ext) in [("RIFF", "wav"), ("caff", "caf"), ("ID3a", "mp3")] {
            try Data((header + String(repeating: "x", count: 32)).utf8).write(to: input)
            XCTAssertEqual(try TrackAudioCache.nativeExtension(for: input), ext)
        }
        try Data("{\"error\":\"server unavailable\"}".utf8).write(to: input)
        XCTAssertThrowsError(try TrackAudioCache.nativeExtension(for: input))
    }

    func testActionableErrorsNeverExposeCodeZero() {
        let wrapped = NSError(domain: "wrapper", code: 0,
            userInfo: [NSUnderlyingErrorKey: URLError(.notConnectedToInternet)])
        XCTAssertTrue(DownloadFailureMessage.describe(wrapped).contains("Sem conexão"))
        XCTAssertTrue(DownloadFailureMessage.describe(wrapped, status: 503).contains("HTTP 503"))
        XCTAssertFalse(DownloadFailureMessage.describe(NSError(domain: "audio", code: 0)).contains("0"))
    }

    func testRateLimitedDownloadShowsUpstreamWaitNotColdStart() {
        let error = URLError(.badServerResponse)
        let youtube = DownloadFailureMessage.describe(
            error, status: 429, serverCode: "upstream_rate_limited", retryAfter: 300)
        XCTAssertTrue(youtube.contains("YouTube"))
        XCTAssertTrue(youtube.contains("5 min"))
        XCTAssertFalse(youtube.contains("acordando"))
        let busy = DownloadFailureMessage.describe(
            error, status: 429, serverCode: "queue_full", retryAfter: 30)
        XCTAssertTrue(busy.contains("fila"))
        XCTAssertTrue(busy.contains("30 s"))
        XCTAssertTrue(DownloadFailureMessage.describe(
            error, status: 429, serverCode: nil, retryAfter: 60).contains("HTTP 429"))
    }

    func testMissingMetadataIsNotInvented() {
        for label in ["Não identificado", "Unknown Artist", "Unknown Album", "Artista não identificado"] {
            XCTAssertNil(AlbumArtistCollectionResolver.normalize(label))
        }
        let track = Track(id: "abcdefghijk", title: "Artist - Song", thumbnailURL: nil,
                          cleanArtist: "Não identificado", album: "Unknown Album")
        XCTAssertEqual(AlbumArtistCollectionResolver.artistName(for: track), "Artist")
        XCTAssertNil(AlbumArtistCollectionResolver.albumTitle(for: track))
        XCTAssertEqual(MusicCatalogService.query(for: track), "Artist Song")
        let official = Track(id: "12345678901", title: "Song (Official Audio)",
                             thumbnailURL: nil, cleanArtist: "Artist - Topic")
        XCTAssertEqual(MusicCatalogService.bestMatch([official], for: track)?.id, official.id)
    }

    func testOfflineCatalogRetainsDeterministicLocalTracks() async {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [Stage42OfflineProtocol.self]
        let service = MusicCatalogService(session: URLSession(configuration: config))
        let a = Track(id: "a", title: "One", thumbnailURL: nil, cleanArtist: "Artist", album: "Album", trackNumber: 1)
        let b = Track(id: "b", title: "Two", thumbnailURL: nil, cleanArtist: "Artist", album: "Album", trackNumber: 2)
        let result = await service.collection(anchor: a, local: [b], mode: .album)
        XCTAssertEqual(result.playbackTracks.map(\.id), ["a", "b"])
    }

    func testLiveCatalogLookupAndOneTapStreamResolutionWithFixtures() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [Stage42CatalogProtocol.self]
        let service = MusicCatalogService(session: URLSession(configuration: config))
        let anchor = Track(id: "abcdefghijk", title: "Artist - Song", thumbnailURL: nil)
        let result = await service.collection(anchor: anchor, local: [], mode: .both)
        XCTAssertEqual(result.artistName, "Artist")
        XCTAssertEqual(result.albumTitle, "Studio Album")
        XCTAssertEqual(result.albumTracks.count, 3)
        XCTAssertGreaterThanOrEqual(result.playbackTracks.count, 20)
        let catalogTrack = try XCTUnwrap(result.albumTracks.first { $0.id.hasPrefix("itunes-") })
        let playable = try await service.playable(catalogTrack, baseURL: "https://fixture.test")
        XCTAssertEqual(playable.id, catalogTrack.id)
        XCTAssertEqual(playable.streamVideoID, "12345678901")
        XCTAssertEqual(playable.url.absoluteString, "https://www.youtube.com/watch?v=12345678901")
    }

    func testDrawerAndLyricsCannotPauseOrStartHeavyWork() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("NightcoreLab/Sources")
        func source(_ file: String) throws -> String { try String(contentsOf: root.appendingPathComponent(file)) }
        let screen = try source("NowPlayingScreen.swift")
        XCTAssertFalse(screen.contains("isPaused: searchDrawer.isOpen"))
        XCTAssertTrue(screen.contains("@GestureState private var dragTranslation"))
        XCTAssertFalse(try source("LyricsStore.swift").contains("StemSplitterEngine.prepare"))
        XCTAssertFalse(try source("AudioDownloadManager.swift").contains("transcodeAAC"))
        XCTAssertTrue(try source("AudioDownloadManager.swift").contains("setMaxConcurrentDownloads(2)"))
    }

    func testValidResolvedCatalogIDNeedsNoMetadataRequest() async throws {
        let token = CatalogResolutionProbe.shared.configure(rejectAll: true)
        let service = catalogService(token: token)
        let song = Track(id: "itunes-58", title: "Song", thumbnailURL: nil,
                         cleanArtist: "Artist", streamVideoID: "12345678901")
        let result = try await service.playable(song, baseURL: "https://fixture.test")
        XCTAssertEqual(result, song)
        XCTAssertEqual(CatalogResolutionProbe.shared.count(token), 0)
    }

    func testDirectStrictMatchDoesNotWaitForSleepingRender() async throws {
        let token = CatalogResolutionProbe.shared.configure()
        let service = catalogService(token: token)
        let done = expectation(description: "Device-direct match wins before the held Render response")
        let task = Task {
            do {
                let result = try await service.playable(
                    Track(id: "itunes-58", title: "Song", thumbnailURL: nil, cleanArtist: "Artist"),
                    baseURL: "https://fixture.test")
                XCTAssertEqual(result.streamVideoID, "12345678901")
            } catch { XCTFail("Direct catalog resolution failed: \(error)") }
            done.fulfill()
        }
        defer { task.cancel() }
        await fulfillment(of: [done], timeout: 5)
    }

    func testResolvedCatalogMappingSurvivesRestartAndRejectsChangedMetadataAndExpiry() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("streams.json")
        let first = catalogService(token: CatalogResolutionProbe.shared.configure(), cache: file)
        let song = Track(id: "itunes-58", title: "Song", thumbnailURL: nil, cleanArtist: "Artist")
        _ = try await first.playable(song, baseURL: "https://fixture.test")
        await first.flushStreamCache()
        let rejectToken = CatalogResolutionProbe.shared.configure(rejectAll: true)
        let restored = catalogService(token: rejectToken, cache: file)
        let cached = try await restored.playable(song, baseURL: "https://fixture.test")
        XCTAssertEqual(cached.streamVideoID, "12345678901")
        XCTAssertEqual(CatalogResolutionProbe.shared.count(rejectToken), 0)
        do {
            _ = try await restored.playable(Track(id: song.id, title: "Another Song", thumbnailURL: nil,
                                                 cleanArtist: "Artist"), baseURL: "https://fixture.test")
            XCTFail("A mapping for changed metadata must not be reused")
        } catch {}
        var payload = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: [String: Any]])
        for key in payload.keys { payload[key]?["expiresAt"] = Date.distantPast.timeIntervalSinceReferenceDate }
        try JSONSerialization.data(withJSONObject: payload).write(to: file)
        let expired = catalogService(token: CatalogResolutionProbe.shared.configure(rejectAll: true), cache: file)
        do {
            _ = try await expired.playable(song, baseURL: "https://fixture.test")
            XCTFail("An expired mapping must not be reused")
        } catch {}
    }

    private func catalogService(token: String, cache: URL? = nil) -> MusicCatalogService {
        let config = URLSessionConfiguration.ephemeral
        config.httpAdditionalHeaders = ["X-Gnarly-Test": token]
        config.protocolClasses = [CatalogResolutionProtocol.self]
        return MusicCatalogService(session: URLSession(configuration: config), streamCacheURL: cache)
    }
}

private final class CatalogResolutionProbe: @unchecked Sendable {
    static let shared = CatalogResolutionProbe()
    private let lock = NSLock()
    private var reject = Set<String>()
    private var counts: [String: Int] = [:]
    func configure(rejectAll: Bool = false) -> String {
        let token = UUID().uuidString
        lock.lock(); defer { lock.unlock() }
        if rejectAll { reject.insert(token) }
        return token
    }
    func record(_ token: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        counts[token, default: 0] += 1
        return reject.contains(token)
    }
    func count(_ token: String) -> Int {
        lock.lock(); defer { lock.unlock() }
        return counts[token, default: 0]
    }
}

private final class CatalogResolutionProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let token = request.value(forHTTPHeaderField: "X-Gnarly-Test") ?? ""
        if CatalogResolutionProbe.shared.record(token) {
            client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet)); return
        }
        guard request.url!.host != "fixture.test" else { return } // sleeping Render
        let payload: [String: Any] = ["musicResponsiveListItemRenderer": [
            "playlistItemData": ["videoId": "12345678901"],
            "flexColumns": [["musicResponsiveListItemFlexColumnRenderer": ["text": ["runs": [
                ["text": "Song"], ["text": "Artist", "navigationEndpoint": ["browseEndpoint": ["browseId": "UCartist"]]]
            ]]]]]
        ]]
        let data = try! JSONSerialization.data(withJSONObject: payload)
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200,
            httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

private final class Stage42OfflineProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() { client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet)) }
    override func stopLoading() {}
}

private final class Stage42CatalogProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let url = request.url!
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let id = query.first { $0.name == "id" }?.value
        var payload: Any
        if url.host == "fixture.test" {
            let text = query.first { $0.name == "q" }?.value ?? ""
            let title = text.contains("Song 2") ? "Song 2" : "Song 3"
            payload = [["id": "12345678901", "title": title, "artist": "Artist", "isSong": true, "explicit": false]]
        } else {
            let count = url.path == "/search" ? 1 : (id == "100" ? 3 : 25)
            payload = ["results": (1...count).map { i -> [String: Any] in
                ["trackId": i, "trackName": i == 1 ? "Song" : "Song \(i)",
                 "artistName": "Artist", "collectionName": i <= 3 ? "Studio Album" : "Other",
                 "collectionId": i <= 3 ? 100 : 101, "artistId": 200, "trackNumber": i]
            }]
        }
        let data = try! JSONSerialization.data(withJSONObject: payload)
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
