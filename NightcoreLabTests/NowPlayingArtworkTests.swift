import CoreImage
import AVFoundation
import MediaPlayer
import UIKit
import XCTest
@testable import NightcoreLab

@MainActor
final class NowPlayingArtworkTests: XCTestCase {
    func testConcurrentPlayerSurfacesShareOneDecodeAndReleaseOnPressure() async throws {
        let image = UIGraphicsImageRenderer(size: CGSize(width: 40, height: 40)).image { context in
            UIColor.red.setFill(); context.fill(CGRect(x: 0, y: 0, width: 40, height: 40))
        }
        let bytes = try XCTUnwrap(image.pngData())
        actor Reads {
            var count = 0
            func read(_ bytes: Data) async -> Data {
                count += 1
                try? await Task.sleep(for: .milliseconds(25))
                return bytes
            }
        }
        let reads = Reads()
        let store = PlayerArtworkStore { _ in await reads.read(bytes) }
        let url = URL(fileURLWithPath: "/fixture/shared-cover.png")
        async let first = store.image(at: url)
        async let second = store.image(at: url)
        let (a, b) = await (first, second)
        XCTAssertNotNil(a)
        XCTAssertTrue(a === b, "Player/background/system surfaces must share the decoded bitmap")
        let initialReads = await reads.count
        XCTAssertEqual(initialReads, 1)
        let cached = await store.image(at: url)
        XCTAssertTrue(a === cached)
        await store.removeAll()
        let afterPressure = await store.image(at: url)
        XCTAssertFalse(a === afterPressure)
        let finalReads = await reads.count
        XCTAssertEqual(finalReads, 2)
    }

    func testCIBackedCoverBecomesRequestedBitmapArtwork() throws {
        let ciImage = CIImage(color: CIColor(red: 1, green: 0, blue: 0, alpha: 1))
            .cropped(to: CGRect(x: 0, y: 0, width: 48, height: 48))
        let artwork = try XCTUnwrap(NowPlayingArtworkLoader.artwork(UIImage(ciImage: ciImage)))
        let rendered = try XCTUnwrap(artwork.image(at: CGSize(width: 96, height: 96)))
        XCTAssertNotNil(rendered.cgImage)
        XCTAssertEqual(rendered.size, CGSize(width: 96, height: 96))
    }

    func testDownloadedCoverSurvivesCacheReloadForBothPlayers() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var cache = TrackAudioCache(folder: root.appendingPathComponent("audio"))
        let track = Track(id: "offline0001", title: "Offline",
                          thumbnailURL: URL(string: "https://unavailable.invalid/cover.jpg"))
        let source = root.appendingPathComponent("source.caf")
        try writeAudio(source)
        _ = try cache.store(track, from: source)
        let red = UIGraphicsImageRenderer(size: CGSize(width: 40, height: 40)).image { context in
            UIColor.red.setFill(); context.fill(CGRect(x: 0, y: 0, width: 40, height: 40))
        }
        let bytes = try XCTUnwrap(red.pngData())
        let stored = try XCTUnwrap(cache.storeArtwork(bytes, for: track.id))
        let restarted = TrackAudioCache(folder: cache.folder)
        let local = try XCTUnwrap(restarted.artworkURL(for: track.id))
        XCTAssertEqual(local, stored)
        let playerTrack = TrackInfo(track: track, fileName: nil, coverURL: local)
        let internalImage = await NowPlayingArtworkLoader.coverImage(at: try XCTUnwrap(playerTrack.coverURL))
        let systemArtwork = await NowPlayingArtworkLoader.load(coverURL: local, mediaURL: nil)
        XCTAssertNotNil(internalImage?.cgImage)
        let externalImage = try XCTUnwrap(systemArtwork?.image(at: CGSize(width: 80, height: 80)))
        XCTAssertEqual(externalImage.size, CGSize(width: 80, height: 80))
        XCTAssertEqual(ArtworkTintExtractor.extract(from: try XCTUnwrap(internalImage?.pngData()))?.hue ?? -1,
                       ArtworkTintExtractor.extract(from: try XCTUnwrap(externalImage.pngData()))?.hue ?? -2,
                       accuracy: 0.01)
        let shareImage = await ShareRenderer.loadArtwork(local)
        XCTAssertNotNil(shareImage, "The same local cover must remain usable by Share")
    }

    func testInvalidCoverCannotReplaceSavedArtworkAndDeletingAudioRemovesIt() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var cache = TrackAudioCache(folder: root.appendingPathComponent("audio"))
        let track = Track(id: "offline0002", title: "Offline", thumbnailURL: nil)
        let source = root.appendingPathComponent("source.caf")
        try writeAudio(source)
        _ = try cache.store(track, from: source)
        let cover = UIGraphicsImageRenderer(size: CGSize(width: 20, height: 20)).image { context in
            UIColor.blue.setFill(); context.fill(CGRect(x: 0, y: 0, width: 20, height: 20))
        }
        let bytes = try XCTUnwrap(cover.pngData())
        let local = try XCTUnwrap(cache.storeArtwork(bytes, for: track.id))
        XCTAssertNil(try cache.storeArtwork(Data("<html>offline error</html>".utf8), for: track.id))
        XCTAssertEqual(try Data(contentsOf: local), bytes)
        try cache.remove(track.id)
        XCTAssertFalse(FileManager.default.fileExists(atPath: local.path))
        XCTAssertNil(TrackAudioCache(folder: cache.folder).artworkURL(for: track.id))
    }

    func testThumbnailKeepsProviderFirstAndUsesStableYouTubeBackup() {
        let primary = URL(string: "https://cdn.example.org/ephemeral-cover.jpg")!
        let track = Track(id: "dQw4w9WgXcQ", title: "Fixture", thumbnailURL: primary)
        XCTAssertEqual(track.artworkCandidateURLs, [
            primary, URL(string: "https://i.ytimg.com/vi/dQw4w9WgXcQ/hqdefault.jpg")!
        ])
        let defaultCover = Track.from(url: "https://www.youtube.com/watch?v=dQw4w9WgXcQ")!
        XCTAssertEqual(defaultCover.artworkCandidateURLs.count, 1,
                       "Do not retry the exact same image URL as a second candidate")
    }

    func testOtherCatalogTracksDoNotInventYouTubeArtwork() {
        let primary = URL(string: "https://example.org/deezer-cover.jpg")!
        let track = Track(id: "deezer-123", title: "Fixture", thumbnailURL: primary)
        XCTAssertEqual(track.artworkCandidateURLs, [primary])
        XCTAssertTrue(Track(id: "local-file", title: "Local", thumbnailURL: nil)
            .artworkCandidateURLs.isEmpty)
    }

    func testArtworkStoreFailureDoesNotPoisonNextRetry() async throws {
        let image = UIGraphicsImageRenderer(size: CGSize(width: 24, height: 24)).image { context in
            UIColor.green.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 24, height: 24))
        }
        let bytes = try XCTUnwrap(image.pngData())
        actor IntermittentLoader {
            var reads = 0
            func data(_ bytes: Data) -> Data? {
                reads += 1
                return reads == 1 ? nil : bytes
            }
        }
        let loader = IntermittentLoader()
        let store = PlayerArtworkStore { _ in await loader.data(bytes) }
        let url = URL(string: "https://example.org/transient.jpg")!
        let failed = await store.image(at: url)
        XCTAssertNil(failed)
        let recovered = await store.image(at: url)
        XCTAssertNotNil(recovered)
        let reads = await loader.reads
        XCTAssertEqual(reads, 2)
    }

    private func writeAudio(_ url: URL) throws {
        let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 128)!
        buffer.frameLength = 128
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
    }

    func testLegacyFlatAudioEntriesKeepSeparateCoversAndDeleteOnlyOneTrack() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let first = Track(id: "legacy00001", title: "First", thumbnailURL: nil)
        let second = Track(id: "legacy00002", title: "Second", thumbnailURL: nil)
        try writeAudio(root.appendingPathComponent("first.caf"))
        try writeAudio(root.appendingPathComponent("second.caf"))
        let index = [
            first.id: TrackAudioCache.Entry(track: first, relativePath: "first.caf", accessedAt: .now),
            second.id: TrackAudioCache.Entry(track: second, relativePath: "second.caf", accessedAt: .now)
        ]
        try JSONEncoder().encode(index).write(to: root.appendingPathComponent("index.json"))
        var cache = TrackAudioCache(folder: root)
        let image = UIGraphicsImageRenderer(size: CGSize(width: 8, height: 8)).image { context in
            UIColor.red.setFill(); context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        }
        let bytes = try XCTUnwrap(image.pngData())
        let firstCover = try XCTUnwrap(cache.storeArtwork(bytes, for: first.id))
        let secondCover = try XCTUnwrap(cache.storeArtwork(bytes, for: second.id))
        XCTAssertNotEqual(firstCover, secondCover)
        try cache.remove(first.id)
        XCTAssertFalse(FileManager.default.fileExists(atPath: firstCover.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: secondCover.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("second.caf").path))
        var reloaded = TrackAudioCache(folder: root)
        XCTAssertNotNil(reloaded.localURL(for: second.id))
    }
}
