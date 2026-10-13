import AVFoundation
import SwiftUI
import UIKit
import XCTest
@testable import NightcoreLab

final class ShareExportPipelineTests: XCTestCase {
    private func request(mode: StoryMode = .player,
                         duration: TimeInterval = 120) throws -> StoryVideoRequest {
        let track = TrackInfo(
            track: Track(id: "12345678901", title: "Export Sample",
                         thumbnailURL: nil, cleanArtist: "Test Artist"),
            fileName: nil, coverURL: nil)
        return try StoryRequestBuilder.make(
            mode: mode, track: track, theme: .acid,
            playerStyle: .turbulent, karaokeBackground: .marble,
            marblePhase: 2.1, playbackTime: duration - 0.35,
            sourceDuration: duration, speed: 1, lines: [],
            lyricOffset: 0, typography: .classic, includeAudio: false)
    }

    func testLegacyRecommendedProfileDoesNotChange() {
        let old = StoryEncodingProfile.recommended()
        let profile = ExportProfile.matching(old).encodingProfile(for: .player)
        XCTAssertEqual(old.width, profile.width)
        XCTAssertEqual(old.height, profile.height)
        XCTAssertEqual(old.fps, profile.fps)
        XCTAssertEqual(old.bitRate, profile.bitRate)
        XCTAssertEqual(profile.cropPolicy, .safeAreaPreserving)
    }

    func testFormatQualityMatrixAndFrameRate() {
        for quality in ExportQuality.allCases {
            for ratio in ExportAspectRatio.allCases {
                let profile = ExportProfile(
                    aspectRatio: ratio, quality: quality
                ).encodingProfile(for: .player)
                let expected: (Int, Int)
                switch ratio {
                case .portrait: expected = (9, 16)
                case .square: expected = (1, 1)
                case .landscape: expected = (16, 9)
                }
                XCTAssertEqual(profile.width * expected.1,
                               profile.height * expected.0)
                XCTAssertEqual(profile.width % 2, 0)
                XCTAssertEqual(profile.height % 2, 0)
                XCTAssertGreaterThan(profile.bitRate, 0)
                XCTAssertEqual(profile.fps, quality == .economy ? 15 :
                               quality == .balanced ? 20 : 30)
            }
        }
        XCTAssertEqual(ExportProfile().encodingProfile(for: .player).width, 720)
        XCTAssertEqual(ExportProfile().encodingProfile(for: .player).height, 1280)
    }

    func testLyricsNeverUseUnsafeCenterCrop() {
        let crop = ExportProfile(aspectRatio: .landscape,
                                 quality: .balanced, cropPolicy: .centerCrop)
        XCTAssertEqual(crop.encodingProfile(for: .lyrics).cropPolicy,
                       .safeAreaPreserving)
        XCTAssertEqual(crop.encodingProfile(for: .player).cropPolicy,
                       .centerCrop)
    }

    func testProfileCodableRoundTripAndMetadataVersion() throws {
        let value = ExportProfile(aspectRatio: .square, quality: .high,
                                  cropPolicy: .aspectFit)
        let bytes = try JSONEncoder().encode(value)
        XCTAssertEqual(try JSONDecoder().decode(ExportProfile.self, from: bytes), value)

        let stamp = Date(timeIntervalSince1970: 1_700_000_000)
        let metadata = ShareMetadata(
            schemaVersion: 1, title: "Song", artist: "Artist",
            presetID: "original", materialID: "original-marble",
            duration: 4, width: 720, height: 720, fps: 20,
            codec: "h264", quality: .balanced, aspectRatio: .square,
            cropPolicy: .safeAreaPreserving,
            thumbnailFrameIndex: 0, thumbnailElapsed: 0, exportedAt: stamp)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        XCTAssertEqual(try decoder.decode(ShareMetadata.self,
                                          from: encoder.encode(metadata)), metadata)
    }

    @MainActor
    func testSharedCanvasRendersThreeRatiosWithoutChangingSceneSource() throws {
        let clip = try request()
        for ratio in ExportAspectRatio.allCases {
            let profile = ExportProfile(aspectRatio: ratio, quality: .economy)
                .encodingProfile(for: clip.mode)
            let frame = StoryRenderTimeline(request: clip, profile: profile).frame(index: 1)
            let image = try StoryFrameRenderer.render(
                request: clip, artwork: nil, frame: frame, profile: profile)
            XCTAssertEqual(image.width, profile.width)
            XCTAssertEqual(image.height, profile.height)
        }
    }

    @MainActor
    func testDefaultPortraitPreviewAndEncoderShareExactPixels() throws {
        let clip = try request()
        let profile = StoryEncodingProfile.balanced
        let frame = StoryRenderTimeline(request: clip, profile: profile).frame(index: 1)
        let exported = try StoryFrameRenderer.render(
            request: clip, artwork: nil, frame: frame, profile: profile)
        let sameCanvas = StoryExportCanvas(request: clip, artwork: nil,
                                           frame: frame, profile: profile)
        XCTAssertTrue(sameCanvas.isLegacyPortrait)
        XCTAssertEqual(sameCanvas.logicalSize, StoryVideoRequest.size)
        let preview = ImageRenderer(content: sameCanvas)
        preview.proposedSize = ProposedViewSize(sameCanvas.logicalSize)
        preview.scale = profile.scale
        let pixels = try XCTUnwrap(preview.uiImage?.cgImage)
        XCTAssertEqual(pixels.width, exported.width)
        XCTAssertEqual(pixels.height, exported.height)
        let resolved = clip.resolvedFrame(frame, audioTimeline: nil, rhythm: nil)
        XCTAssertEqual(StorySceneView(request: clip, artwork: nil, frame: frame).materialFrame,
                       resolved?.materialFrame)
    }

    @MainActor
    func testSharePackageContainsValidatedVideoThumbnailAndMetadata() async throws {
        let clip = try request()
        let profile = ExportProfile(aspectRatio: .square, quality: .economy,
                                    cropPolicy: .safeAreaPreserving)
        let output = try await SharePackageBuilder.build(
            request: clip, audioSource: nil, artwork: nil,
            selectedProfile: profile, visualTimeline: nil, visualRhythm: nil,
            progress: { _ in })
        defer { try? FileManager.default.removeItem(
            at: output.videoURL.deletingLastPathComponent()) }
        XCTAssertEqual(output.files.count, 3)
        for file in output.files {
            XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
            XCTAssertGreaterThan(try Data(contentsOf: file).count, 0)
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let metadata = try decoder.decode(
            ShareMetadata.self, from: Data(contentsOf: output.metadataURL))
        XCTAssertEqual(metadata, output.metadata)
        XCTAssertEqual(metadata.width, 540)
        XCTAssertEqual(metadata.height, 540)
        XCTAssertEqual(metadata.thumbnailFrameIndex, 0)
        let thumb = try XCTUnwrap(UIImage(contentsOfFile: output.thumbnailURL.path))
        XCTAssertEqual(thumb.cgImage?.width, 540)
        XCTAssertEqual(thumb.cgImage?.height, 540)

        let asset = AVURLAsset(url: output.videoURL)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        let video = try XCTUnwrap(tracks.first)
        let size = try await video.load(.naturalSize)
        XCTAssertEqual(size.width, 540)
        XCTAssertEqual(size.height, 540)
    }
}
