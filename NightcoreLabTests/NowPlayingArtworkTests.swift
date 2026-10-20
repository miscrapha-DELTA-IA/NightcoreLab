import CoreImage
import AVFoundation
import MediaPlayer
import UIKit
import XCTest
@testable import NightcoreLab

@MainActor
final class NowPlayingArtworkTests: XCTestCase {
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

    private func writeAudio(_ url: URL) throws {
        let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 128)!
        buffer.frameLength = 128
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
    }
}
