import XCTest
import SwiftUI
import AVFoundation
import CoreImage
import UIKit
@testable import NightcoreLab

final class StoryVideoTests: XCTestCase {
    private func track() -> TrackInfo {
        TrackInfo(track: Track(id: "12345678901", title: "Demo · Artist",
                               thumbnailURL: nil, cleanArtist: "Artist"),
                  fileName: nil, coverURL: nil)
    }

    private func line() -> TimedLyricLine {
        TimedLyricLine(id: 0, start: 5, end: 8, words: [
            WordSync(id: 0, text: "Hello", start: 5, end: 6, spaceAfter: true),
            WordSync(id: 1, text: "world", start: 6, end: 8, spaceAfter: false)
        ], precision: .word)
    }

    private func request(mode: StoryMode, start: TimeInterval = 4,
                         total: TimeInterval = 120,
                         speed: Float = 1, hasLyrics: Bool = true) throws -> StoryVideoRequest {
        try StoryRequestBuilder.make(
            mode: mode, track: track(), theme: .acid,
            playerStyle: .turbulent, karaokeBackground: .marble,
            marblePhase: 2.3, playbackTime: start, sourceDuration: total,
            speed: speed, lines: hasLyrics ? [line()] : [],
            lyricOffset: 0.2, typography: .classic, includeAudio: false)
    }

    func testStoryFramesUseOriginalAudioTimeAndDeterministicShaderPhase() throws {
        let clip = try request(mode: .lyrics, speed: 1.25)
        XCTAssertEqual(clip.duration, 15, accuracy: 0.00001)
        XCTAssertEqual(clip.frameCount, 450)
        XCTAssertEqual(clip.sourceTime(at: 10), 16.5, accuracy: 0.00001)
        XCTAssertEqual(clip.lyricTime(at: 10), 16.7, accuracy: 0.00001)
        XCTAssertEqual(clip.marbleTime(at: 2), 3.9, accuracy: 0.001)
    }

    func testStoryClampsToEndInsteadOfLoopingSound() throws {
        let clip = try request(mode: .player, start: 98, total: 100, speed: 1.25)
        XCTAssertEqual(clip.duration, 1.6, accuracy: 0.0001)
        XCTAssertEqual(clip.frameCount, 48)
        XCTAssertEqual(clip.sourceTime(at: clip.duration), 100, accuracy: 0.0001)
    }

    func testUnavailableLyricsDisablesLyricStoryButNotPlayerStory() throws {
        XCTAssertThrowsError(try request(mode: .lyrics, hasLyrics: false))
        let player = try request(mode: .player, hasLyrics: false)
        XCTAssertFalse(player.canExportLyrics)
        XCTAssertEqual(player.duration, 15)
    }

    func testWordProgressAtArbitraryFrameIsNotGuessed() throws {
        let clip = try request(mode: .lyrics, start: 4.5)
        let active = try XCTUnwrap(clip.activeLine(at: 1))
        XCTAssertEqual(active.words.first?.progress(at: clip.lyricTime(at: 1)) ?? -1,
                       0.7, accuracy: 0.0001)
        XCTAssertNil(clip.activeLine(at: 8))
    }

    func testEveryTypographyHasStableIdentifier() {
        XCTAssertEqual(Set(StoryLyricTypography.allCases.map(\.id)).count,
                       StoryLyricTypography.allCases.count)
    }

    func testEncodingProfilesReduceExpensiveMetalWork() {
        let balanced = StoryEncodingProfile.balanced
        let economical = StoryEncodingProfile.economical
        XCTAssertEqual(balanced.width, 720)
        XCTAssertEqual(balanced.height, 1280)
        XCTAssertEqual(balanced.frameCount(duration: 15), 300)
        XCTAssertEqual(economical.width, 540)
        XCTAssertEqual(economical.height, 960)
        XCTAssertEqual(economical.frameCount(duration: 15), 225)
        XCTAssertLessThan(balanced.frameCount(duration: 15) *
                          balanced.width * balanced.height,
                          450 * 1080 * 1920)
    }

    /// Encodes/decodes a diagnostic portrait chart through the same H.264 writer.
    /// Avoids relying on metadata or the image dimensions to determine orientation.
    @MainActor
    func testEncodedMP4PreservesUprightPortraitOrientation() async throws {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 128, height: 256))
        let chart = renderer.image { _ in
            UIColor.red.setFill()
            UIRectFill(CGRect(x: 0, y: 0, width: 128, height: 128))
            UIColor.blue.setFill()
            UIRectFill(CGRect(x: 0, y: 128, width: 128, height: 128))
        }
        let url = try await StoryVideoExporter.encodeOrientationProbe(
            try XCTUnwrap(chart.cgImage))
        defer { try? FileManager.default.removeItem(at: url) }
        let asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        let track = try XCTUnwrap(tracks.first)
        let size = try await track.load(.naturalSize)
        XCTAssertLessThan(size.width, size.height)

        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        let output = try generator.copyCGImage(
            at: CMTime(value: 0, timescale: 1), actualTime: nil)
        XCTAssertLessThan(output.width, output.height)
        let ciImage = CIImage(cgImage: output)
        let context = CIContext(options: [.useSoftwareRenderer: true])
        func pixel(y: CGFloat) -> (red: UInt8, blue: UInt8) {
            let rect = CGRect(x: ciImage.extent.midX, y: y, width: 1, height: 1)
            var bytes = [UInt8](repeating: 0, count: 4)
            context.render(ciImage.cropped(to: rect), toBitmap: &bytes,
                           rowBytes: 4, bounds: rect, format: .RGBA8,
                           colorSpace: CGColorSpaceCreateDeviceRGB())
            return (bytes[0], bytes[2])
        }
        let top = pixel(y: ciImage.extent.maxY - 8)
        let bottom = pixel(y: ciImage.extent.minY + 8)
        XCTAssertGreaterThan(Int(top.red), Int(top.blue) + 80,
                             "The red TOP half is inverted in the encoded video")
        XCTAssertGreaterThan(Int(bottom.blue), Int(bottom.red) + 80,
                             "The blue BOTTOM half is inverted in the encoded video")
    }

    @MainActor
    func testSingleStoryFrameRendersWithoutNetwork() throws {
        let clip = try request(mode: .player)
        let renderer = ImageRenderer(content: StorySceneView(
            request: clip, artwork: nil, elapsed: 1.0))
        renderer.proposedSize = ProposedViewSize(StoryVideoRequest.size)
        renderer.scale = 2
        let image = try XCTUnwrap(renderer.uiImage)
        XCTAssertEqual(image.size.width * image.scale, 1080, accuracy: 1)
        XCTAssertEqual(image.size.height * image.scale, 1920, accuracy: 1)
    }
}
