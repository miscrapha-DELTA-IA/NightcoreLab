import Foundation
import SwiftUI
import XCTest
@testable import NightcoreLab

final class CreatorControlTests: XCTestCase {
    private func clip(mode: StoryMode = .player) throws -> StoryVideoRequest {
        let track = TrackInfo(track: Track(
            id: "12345678901", title: "Creator", thumbnailURL: nil,
            cleanArtist: "Nightcore"), fileName: nil, coverURL: nil)
        let words = [WordSync(id: 0, text: "HELLO", start: 1, end: 5, spaceAfter: true),
                     WordSync(id: 1, text: "WORLD", start: 5, end: 10, spaceAfter: false)]
        let lines = [TimedLyricLine(id: 9, start: 1, end: 10,
                                    words: words, precision: .word)]
        return try StoryRequestBuilder.make(
            mode: mode, track: track, theme: .acid,
            playerStyle: .turbulent, karaokeBackground: .marble,
            marblePhase: 0.5, playbackTime: 2, sourceDuration: 10,
            speed: 1, lines: mode == .lyrics ? lines : [],
            lyricOffset: 0, typography: .classic,
            typographyStyle: .magazineCutout, includeAudio: false)
    }

    func testEveryControlMapsToItsDedicatedCreativeParameter() {
        let neutral = ControlMapping.resolve(.neutral)
        XCTAssertTrue(neutral.isNeutral)
        for control in CreatorControl.allCases {
            var values = CreatorControls()
            values.set(0.83, for: control)
            let resolved = ControlMapping.resolve(values)
            XCTAssertFalse(resolved.isNeutral, "\(control) is not mapped")
            switch control {
            case .materialIntensity:
                XCTAssertNotEqual(resolved.intensity, neutral.intensity)
            case .distortion:
                XCTAssertNotEqual(resolved.distortion, neutral.distortion)
            case .brightness:
                XCTAssertNotEqual(resolved.brightness, neutral.brightness)
            case .movement:
                XCTAssertNotEqual(resolved.movement, neutral.movement)
            case .typographyScale:
                XCTAssertNotEqual(resolved.typographyScale, neutral.typographyScale)
            case .glow:
                XCTAssertNotEqual(resolved.glow, neutral.glow)
            case .kineticAmount:
                XCTAssertNotEqual(resolved.kinetic, neutral.kinetic)
            case .beatSensitivity:
                XCTAssertNotEqual(resolved.beatSensitivity, neutral.beatSensitivity)
            case .energyResponse:
                XCTAssertNotEqual(resolved.energyResponse, neutral.energyResponse)
            }
        }
    }

    func testInvalidNonFiniteControlsAreRejectedWhenDecoding() throws {
        let keys = CreatorControl.allCases.map(\.rawValue)
        var controls = CreatorControls()
        controls.set(Double.nan, for: .brightness)
        XCTAssertEqual(controls.brightness, 0.5)
        let json = #"{"brightness":1.5}"#
        XCTAssertThrowsError(try JSONDecoder().decode(
            CreatorControls.self, from: Data(json.utf8)))
        XCTAssertEqual(keys.count, 9)
    }

    func testPresetPersistsAndRestoresWithoutBackend() throws {
        let suite = "CreatorPreset-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var controls = CreatorControls()
        controls.set(0.78, for: .distortion)
        let source = CreatorPreset(
            experienceID: "cyber-night", materialID: "liquid-glass",
            typography: TypographyPreset(style: .magazineCutout,
                                         deterministicSeed: 0xD123),
            controls: controls, exportProfile: ExportProfile(
                aspectRatio: .square, quality: .high, cropPolicy: .safeAreaPreserving))
        try CreatorPresetStore.save(source, defaults: defaults)
        XCTAssertEqual(CreatorPresetStore.load(defaults: defaults), source)
        let data = try JSONEncoder().encode(source)
        XCTAssertEqual(try JSONDecoder().decode(CreatorPreset.self, from: data), source)
    }

    func testNeutralControlsRetainOriginalMaterialAndTypography() throws {
        let base = try clip(mode: .lyrics)
        let profile = ExportProfile()
        let preset = CreatorPreset(
            experienceID: "original",
            materialID: "original-marble", typography: base.typographyPreset,
            exportProfile: profile)
        let frozen = preset.applying(to: base)
        let frame = StoryRenderTimeline(
            request: base, profile: profile.encodingProfile(for: .lyrics))
            .frame(at: 1)
        let original = base.resolvedFrame(frame, audioTimeline: nil, rhythm: nil)
        let mapped = ControlMapping.apply(
            frozen.resolvedFrame(frame, audioTimeline: nil, rhythm: nil),
            parameters: frozen.creatorParameters)
        XCTAssertEqual(frozen.creatorParameters, .neutral)
        XCTAssertEqual(mapped, original)
    }

    func testSamePresetAndTimestampAlwaysYieldSameFrame() throws {
        let base = try clip(mode: .lyrics)
        var controls = CreatorControls()
        controls.set(0.9, for: .materialIntensity)
        controls.set(0.8, for: .glow)
        controls.set(0.7, for: .beatSensitivity)
        let preset = CreatorPreset(
            experienceID: "original", materialID: "chrome-night",
            typography: base.typographyPreset, controls: controls,
            exportProfile: ExportProfile(aspectRatio: .landscape))
        let frozen = preset.applying(to: base)
        let timeline = StoryRenderTimeline(
            request: frozen, profile: preset.exportProfile.encodingProfile(for: .lyrics))
        let target = timeline.frame(at: 1)
        func sample(_ frame: StoryRenderFrame) -> ResolvedCompositionFrame? {
            ControlMapping.apply(
                frozen.resolvedFrame(frame, audioTimeline: nil, rhythm: nil),
                parameters: frozen.creatorParameters)
        }
        let first = sample(target)
        _ = sample(timeline.frame(at: 3))
        _ = sample(timeline.frame(index: 0))
        XCTAssertEqual(sample(target), first)
        XCTAssertEqual(sample(target)?.materialFrame?.materialID, "chrome-night")
        XCTAssertEqual(sample(target)?.typographyFrame?.words.map(\.seed),
                       first?.typographyFrame?.words.map(\.seed))
    }

    @MainActor
    func testControlledPreviewAndExportUseIdenticalFrame() throws {
        let base = try clip()
        var controls = CreatorControls()
        controls.set(0.84, for: .distortion)
        controls.set(0.73, for: .movement)
        let selected = ExportProfile(aspectRatio: .square, quality: .economy)
        let preset = CreatorPreset(
            experienceID: "original", materialID: "organic-pulse",
            typography: base.typographyPreset,
            controls: controls, exportProfile: selected)
        let request = preset.applying(to: base)
        let encoding = selected.encodingProfile(for: .player)
        let frame = StoryRenderTimeline(request: request, profile: encoding).frame(index: 2)
        let canvas = StoryExportCanvas(
            request: request, artwork: nil, frame: frame, profile: encoding)
        let renderer = ImageRenderer(content: canvas)
        renderer.proposedSize = ProposedViewSize(canvas.logicalSize)
        renderer.scale = CGFloat(encoding.width) / canvas.logicalSize.width
        let preview = try XCTUnwrap(renderer.uiImage?.cgImage)
        let output = try StoryFrameRenderer.render(
            request: request, artwork: nil, frame: frame, profile: encoding)
        XCTAssertEqual(try XCTUnwrap(preview.dataProvider?.data) as Data,
                       try XCTUnwrap(output.dataProvider?.data) as Data)
    }
}