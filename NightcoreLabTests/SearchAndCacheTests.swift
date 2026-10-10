import AVFoundation
import XCTest
@testable import NightcoreLab

final class SearchAndCacheTests: XCTestCase {
    func testNDJSONDecodingDeduplicatesAndFilters() throws {
        let data = Data("""
        {"id":"abcdefghijk","title":"Music","thumbnails":[{"url":"https://i.ytimg.com/a.jpg"}]}
        {"id":"abcdefghijk","title":"Duplicate"}
        {"id":"aaaaaaaaaaa","title":"Live","is_live":true}
        {"id":"bbbbbbbbbbb","title":"Private","availability":"private"}
        {"id":"invalid","title":"Invalid"}
        {"id":"ccccccccccc","title":"Fallback","thumbnail":"http://example.com/image.jpg"}
        """.utf8)
        let tracks = try YouTubeSearchService.decode(data)
        XCTAssertEqual(tracks.map(\.id), ["abcdefghijk", "ccccccccccc"])
        XCTAssertEqual(tracks[0].thumbnailURL?.absoluteString, "https://i.ytimg.com/a.jpg")
        XCTAssertEqual(tracks[1].thumbnailURL?.absoluteString, "https://i.ytimg.com/vi/ccccccccccc/hqdefault.jpg")
        XCTAssertFalse(tracks[0].isCached)
        XCTAssertEqual(try YouTubeSearchService.decode(Data()), [])
        XCTAssertThrowsError(try YouTubeSearchService.decode(Data("not JSON".utf8)))
    }

    func testSearchAndPrefetchLimits() throws {
        let tracks = (0..<20).map { Track(id: String(format: "%011d", $0), title: "Track \($0)", thumbnailURL: nil) }
        let data = Data(tracks.map { "{\"id\":\"\($0.id)\",\"title\":\"\($0.title)\"}" }.joined(separator: "\n").utf8)
        XCTAssertEqual(try YouTubeSearchService.decode(data).count, 15)
        let next = AudioDownloadManager.nextTracks([tracks[0], tracks[1]] + tracks, excluding: tracks[0].id)
        XCTAssertEqual(next.map(\.id), Array(tracks[1...5]).map(\.id))
    }

    func testCanonicalTrackIdentityAcrossLinkFormats() {
        XCTAssertEqual(Track.from(url: "https://youtu.be/abcdefghijk?si=123")?.id,
                       Track.from(url: "https://www.youtube.com/watch?v=abcdefghijk&list=RDx")?.id)
        XCTAssertNil(Track.from(url: "https://youtube.com.evil.test/watch?v=abcdefghijk"))
    }

    func testCachePersistsAndRejectsMissingOrInvalidAudio() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var cache = TrackAudioCache(folder: root.appendingPathComponent("cache"))
        let track = Track(id: "abcdefghijk", title: "Music", thumbnailURL: nil)
        let input = root.appendingPathComponent("source.caf")
        try makeAudio(at: input)
        let saved = try cache.store(track, from: input)
        XCTAssertEqual(cache.localURL(for: track.id), saved)
        XCTAssertTrue(cache.entries[track.id]?.track.isCached == true)
        var restored = TrackAudioCache(folder: cache.folder)
        XCTAssertEqual(restored.localURL(for: track.id), saved)
        try FileManager.default.removeItem(at: saved)
        XCTAssertNil(restored.localURL(for: track.id))
        let invalid = root.appendingPathComponent("error.m4a")
        try Data("{\"detail\":\"error\"}".utf8).write(to: invalid)
        XCTAssertThrowsError(try restored.store(track, from: invalid))
        XCTAssertNil(restored.localURL(for: track.id))
    }

    func testCacheTrimProtectsPlayingTrack() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var cache = TrackAudioCache(folder: root.appendingPathComponent("cache"))
        let protected = "00000000000"
        for index in 0..<32 {
            let input = root.appendingPathComponent("\(index).caf")
            try makeAudio(at: input)
            _ = try cache.store(Track(id: String(format: "%011d", index), title: "Track", thumbnailURL: nil), from: input)
        }
        cache.trim(protecting: [protected])
        XCTAssertEqual(cache.entries.count, 30)
        XCTAssertNotNil(cache.localURL(for: protected))
    }

    private func makeAudio(at url: URL) throws {
        let format = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 2)!
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 128)!
        buffer.frameLength = 128
        for channel in 0..<2 {
            for frame in 0..<128 { buffer.floatChannelData![channel][frame] = 0 }
        }
        try file.write(from: buffer)
    }
}
