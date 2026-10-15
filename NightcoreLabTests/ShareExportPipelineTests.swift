import AVFoundation
import SwiftUI
import UIKit
import XCTest
@testable import NightcoreLab

final class ShareExportPipelineTests: XCTestCase {
    @MainActor
    func testCreatorAndShareUseFrozenTrackHeaderAndOfficialBrand() throws {
        let artworkURL = URL(fileURLWithPath: "/tmp/stage28-cover.jpg")
        let track = TrackInfo(track: Track(id: "stage28", title: "Stage 28 Song",
            thumbnailURL: artworkURL, cleanArtist: "Stage 28 Artist"),
            fileName: nil, coverURL: artworkURL)
        let snapshot = ShareSnapshotBuilder.make(track: track, theme: .acid,
            visualStyle: .marble, marbleStartedAt: .now, speed: 1)
        XCTAssertEqual(snapshot.title, track.title)
        XCTAssertEqual(snapshot.artist, track.artist)
        XCTAssertEqual(snapshot.artworkURL, artworkURL)
        let request = try StoryRequestBuilder.make(mode: .player, track: track,
            theme: .acid, playerStyle: .turbulent, karaokeBackground: .marble,
            marblePhase: 0, playbackTime: 0, sourceDuration: 10, speed: 1,
            lines: [], lyricOffset: 0, typography: .classic, includeAudio: false)
        XCTAssertEqual(request.title, track.title)
        XCTAssertEqual(request.artist, track.artist)
        XCTAssertEqual(request.artworkURL, artworkURL)

        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("NightcoreLab/Sources")
        for file in ["NowPlayingScreen.swift", "Share/StoryDraftPreview.swift",
                     "Share/StorySceneView.swift", "Share/ShareComposer.swift"] {
            let source = try String(contentsOf: root.appendingPathComponent(file))
            XCTAssertTrue(source.contains("NightcoreBrandLockup"), file)
            XCTAssertTrue(source.contains("TrackIdentityPill"), file)
            XCTAssertFalse(source.contains("\"NIGHTCORELAB\""), file)
        }
    }
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

    func testMetadataPreservesLightningReactionAndScoreWithoutClaimingSimulationAsLive() throws {
        var score = KaraokeScoreSnapshot()
        score.judgedVerses = 2
        score.accuracyPercentage = 78
        let stamp = try XCTUnwrap(KaraokePerformanceStamp(
            snapshot: score, mode: .simulation))
        XCTAssertEqual(stamp.grade, "A")
        XCTAssertEqual(stamp.label, "SIMULAÇÃO")
        var metadata = ShareMetadata(
            schemaVersion: ShareMetadata.currentSchemaVersion,
            title: "Song", artist: "Artist", presetID: "cyber-night",
            materialID: "cyber-night", duration: 15, width: 720,
            height: 1280, fps: 20, codec: "h264", quality: .balanced,
            aspectRatio: .portrait, cropPolicy: .safeAreaPreserving,
            thumbnailFrameIndex: 0, thumbnailElapsed: 0, exportedAt: .now)
        metadata.lightningTheme = AppTheme.ultrapink.rawValue
        metadata.reactionMode = CreativePreset.AudioReaction.responsive.rawValue
        metadata.karaokeGrade = stamp.grade
        metadata.karaokeScore = stamp.score
        metadata.karaokeAccuracy = stamp.accuracy
        metadata.karaokeMode = stamp.label
        metadata.padEventCount = 2
        metadata.sectionVisualIntensity = 0.85
        let decoded = try JSONDecoder().decode(ShareMetadata.self,
            from: JSONEncoder().encode(metadata))
        XCTAssertEqual(decoded, metadata)
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

        // Regression baseline: prior to 14A, ImageRenderer directly wrapped
        // StorySceneView without any export canvas or crop adapter.
        let legacy = ImageRenderer(content: StorySceneView(
            request: clip, artwork: nil, frame: frame))
        legacy.proposedSize = ProposedViewSize(StoryVideoRequest.size)
        legacy.scale = profile.scale
        let baseline = try XCTUnwrap(legacy.uiImage?.cgImage)
        let encodedBytes = try XCTUnwrap(exported.dataProvider?.data) as Data
        let previewBytes = try XCTUnwrap(pixels.dataProvider?.data) as Data
        let baselineBytes = try XCTUnwrap(baseline.dataProvider?.data) as Data
        XCTAssertEqual(encodedBytes, baselineBytes,
                       "Default portrait pixels must match the old StorySceneView")
        XCTAssertEqual(previewBytes, encodedBytes,
                       "Preview and video must consume identical visual state")

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
        let bytes = try Data(contentsOf: output.metadataURL)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        // The sidecar's ISO-8601 contract stores seconds, whereas Date() in
        // SharePackage.metadata retains subsecond precision. Assert exact
        // serialized content rather than incorrectly comparing those Dates.
        XCTAssertEqual(bytes, try encoder.encode(output.metadata),
                       "Persisted sidecar must match the full in-memory metadata")

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let metadata = try decoder.decode(ShareMetadata.self, from: bytes)
        let expectedPersisted = try decoder.decode(
            ShareMetadata.self, from: encoder.encode(output.metadata))
        XCTAssertEqual(metadata, expectedPersisted,
                       "Every ShareMetadata field must survive its declared JSON contract")

        // Independent profile expectations; do not mistake Square + Economy
        // for the legacy portrait dimensions.
        let encoding = profile.encodingProfile(for: clip.mode)
        XCTAssertEqual(metadata.schemaVersion, ShareMetadata.currentSchemaVersion)
        XCTAssertEqual(metadata.quality, profile.quality)
        XCTAssertEqual(metadata.aspectRatio, profile.aspectRatio)
        XCTAssertEqual(metadata.cropPolicy, encoding.cropPolicy)
        XCTAssertEqual(metadata.codec, "h264")
        XCTAssertEqual(metadata.width, encoding.width)
        XCTAssertEqual(metadata.height, encoding.height)
        XCTAssertEqual(metadata.fps, encoding.fps)
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
        XCTAssertEqual(size.width, CGFloat(encoding.width))
        XCTAssertEqual(size.height, CGFloat(encoding.height))
        XCTAssertEqual(metadata.thumbnailElapsed, 0)
        XCTAssertFalse(output.videoURL.path.hasPrefix(
            FileManager.default.temporaryDirectory.path))
        output.cleanup()
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.videoURL.path))
    }
}
