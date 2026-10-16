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
