import CoreGraphics
import SwiftUI
import UIKit
import XCTest
@testable import NightcoreLab

final class AdaptiveCompositionLayoutTests: XCTestCase {
    private func clip(mode: StoryMode = .player) throws -> StoryVideoRequest {
        let track = TrackInfo(track: Track(
            id: "12345678901", title: "Adaptive", thumbnailURL: nil,
            cleanArtist: "Nightcore"), fileName: nil, coverURL: nil)
        let words = [WordSync(id: 0, text: "NEON", start: 2, end: 7, spaceAfter: true),
                     WordSync(id: 1, text: "NIGHT", start: 7, end: 12, spaceAfter: false)]
        let lines = [TimedLyricLine(id: 5, start: 2, end: 12,
                                    words: words, precision: .word)]
        return try StoryRequestBuilder.make(
            mode: mode, track: track, theme: .acid,
            playerStyle: .turbulent, karaokeBackground: .marble,
            marblePhase: 1.5, playbackTime: 4, sourceDuration: 12,
            speed: 1, lines: mode == .lyrics ? lines : [],
            lyricOffset: 0, typography: .classic,
            typographyStyle: .magazineCutout, includeAudio: false)
    }

    func testThreeAspectRatiosHaveExplicitSafeZones() {
        for ratio in ExportAspectRatio.allCases {
            let encoding = ExportProfile(aspectRatio: ratio, quality: .balanced)
                .encodingProfile(for: .lyrics)
            let layout = CompositionLayoutPolicy.resolve(profile: encoding, mode: .lyrics)
            XCTAssertEqual(layout.aspectRatio, ratio)
            XCTAssertTrue(layout.canvas.contains(layout.safeArea))
            XCTAssertTrue(layout.canvas.contains(layout.titleArea))
            XCTAssertTrue(layout.canvas.contains(layout.lyricsArea))
            XCTAssertTrue(layout.canvas.contains(layout.mainArea))
            XCTAssertTrue(layout.canvas.contains(layout.footerArea))
            XCTAssertEqual(layout.materialViewport, layout.canvas)
            XCTAssertEqual(layout.materialAspectRatio,
                           CGFloat(encoding.width) / CGFloat(encoding.height),
                           accuracy: 1e-12)
            XCTAssertGreaterThanOrEqual(layout.lyricsArea.minX, layout.safeArea.minX)
            XCTAssertLessThanOrEqual(layout.lyricsArea.maxX, layout.safeArea.maxX)
        }
    }

    func testCroppingNeverTruncatesLyrics() {
        let encoding = ExportProfile(aspectRatio: .landscape, quality: .balanced,
                                     cropPolicy: .centerCrop).encodingProfile(for: .lyrics)
        let layout = CompositionLayoutPolicy.resolve(profile: encoding, mode: .lyrics)
        XCTAssertEqual(layout.cropPolicy, .safeAreaPreserving)
        XCTAssertEqual(layout.lyricsArea.width, 740)
    }

    @MainActor
    func testPortraitOriginalPixelParity() throws {
        let request = try clip()
        let profile = ExportProfile().encodingProfile(for: .player)
        let policy = CompositionLayoutPolicy.resolve(profile: profile, mode: .player)
        XCTAssertTrue(policy.isLegacyPortrait)
        var frozen = request
        frozen.layoutPolicy = policy
        let frame = StoryRenderTimeline(request: frozen, profile: profile).frame(index: 3)
        let image = try StoryFrameRenderer.render(
            request: frozen, artwork: nil, frame: frame, profile: profile)
        let old = ImageRenderer(content: StorySceneView(
            request: request, artwork: nil, frame: frame))
        old.proposedSize = ProposedViewSize(StoryVideoRequest.size)
        old.scale = profile.scale
        let legacy = try XCTUnwrap(old.uiImage?.cgImage)
        XCTAssertEqual(try XCTUnwrap(image.dataProvider?.data) as Data,
                       try XCTUnwrap(legacy.dataProvider?.data) as Data)
    }

    @MainActor
    func testSquareAndLandscapePreviewExportExactPixelsAndViewport() throws {
        for ratio in [ExportAspectRatio.square, .landscape] {
            let request = try clip()
            let selected = ExportProfile(aspectRatio: ratio, quality: .economy)
            let profile = selected.encodingProfile(for: .player)
            var frozen = request
            frozen.layoutPolicy = CompositionLayoutPolicy.resolve(
                profile: profile, mode: frozen.mode)
            let frame = StoryRenderTimeline(request: frozen, profile: profile).frame(index: 2)
            let canvas = StoryExportCanvas(
                request: frozen, artwork: nil, frame: frame, profile: profile)
            let scene = StorySceneView(
                request: frozen, artwork: nil, frame: frame,
                layoutPolicy: frozen.layoutPolicy)
            XCTAssertEqual(try XCTUnwrap(scene.materialFrame.viewport?.aspectRatio),
                           Double(profile.width) / Double(profile.height),
                           accuracy: 1e-12)
            XCTAssertEqual(canvas.logicalSize, frozen.layoutPolicy?.canvasSize)
            let preview = ImageRenderer(content: canvas)
            preview.proposedSize = ProposedViewSize(canvas.logicalSize)
            preview.scale = CGFloat(profile.width) / canvas.logicalSize.width
            let previewPixels = try XCTUnwrap(preview.uiImage?.cgImage)
            let exported = try StoryFrameRenderer.render(
                request: frozen, artwork: nil, frame: frame, profile: profile)
            XCTAssertEqual(exported.width, profile.width)
            XCTAssertEqual(exported.height, profile.height)
            XCTAssertEqual(try XCTUnwrap(previewPixels.dataProvider?.data) as Data,
                           try XCTUnwrap(exported.dataProvider?.data) as Data,
                           "Preview and MP4 renderer must have identical pixels at \(ratio)")
        }
    }

    func testTypographySeedsStayStableAcrossLayoutsAndControls() throws {
        let base = try clip(mode: .lyrics)
        let originalProfile = ExportProfile(aspectRatio: .portrait)
        var control = CreatorControls()
        control.set(0.82, for: .typographyScale)
        control.set(0.91, for: .kineticAmount)
        for ratio in ExportAspectRatio.allCases {
            let preset = CreatorPreset(
                experienceID: "original", materialID: "original-marble",
                typography: base.typographyPreset,
                controls: control, exportProfile: ExportProfile(
                    aspectRatio: ratio, quality: .economy))
            let request = preset.applying(to: base)
            let profile = preset.exportProfile.encodingProfile(for: .lyrics)
            let frame = StoryRenderTimeline(request: request, profile: profile)
                .frame(at: 1)
            let original = base.resolvedFrame(frame, audioTimeline: nil, rhythm: nil)
            let altered = ControlMapping.apply(
                request.resolvedFrame(frame, audioTimeline: nil, rhythm: nil),
                parameters: request.creatorParameters)
            XCTAssertEqual(altered?.typographyFrame?.words.map(\.seed),
                           original?.typographyFrame?.words.map(\.seed))
            XCTAssertEqual(altered?.typographyFrame?.words.map(\.progress),
                           original?.typographyFrame?.words.map(\.progress))
            XCTAssertEqual(altered?.typographyFrame?.words.map(\.magazine),
                           original?.typographyFrame?.words.map(\.magazine))
        }
        XCTAssertEqual(originalProfile.aspectRatio, .portrait)
    }
}