import Foundation
import SwiftUI
import XCTest
@testable import NightcoreLab

final class CreativeMarbleRenderingTests: XCTestCase {
    private let strong = AudioFeatures(
        bass: 0.85, mid: 0.48, treble: 0.24, energy: 0.8,
        beatDetected: false)

    private func audioTimeline() -> AudioFeatureTimeline {
        AudioFeatureTimeline(points: [
            AudioFeaturePoint(time: 0.0, features: .silent),
            AudioFeaturePoint(time: 3.0, features: strong),
            AudioFeaturePoint(time: 3.1, features: strong),
            AudioFeaturePoint(time: 3.2, features: .silent),
            AudioFeaturePoint(time: 3.3, features: .silent)
        ], duration: 4)
    }

    private func request(reaction: CreativePreset.AudioReaction = .responsive,
                         id: String = "bass-pulse",
                         sourceStart: Double = 2,
                         speed: Float = 1,
                         lyricOffset: Double = 0) throws -> StoryVideoRequest {
        let track = TrackInfo(
            track: Track(id: "12345678901", title: "Marble Test",
                         thumbnailURL: nil, cleanArtist: "Nightcore"),
            fileName: nil, coverURL: nil)
        let program: CreativeVisualProgram? = reaction == .off ? nil :
            CreativePresetCatalog.effectiveProgram(
                id: id, theme: .acid, typography: .neon,
                background: .turbulent, reaction: reaction)
        return try StoryRequestBuilder.make(
            mode: .player, track: track, theme: .acid,
            playerStyle: .turbulent, karaokeBackground: .marble,
            marblePhase: 12.5, playbackTime: sourceStart, sourceDuration: 20,
            speed: speed, lines: [], lyricOffset: lyricOffset,
            typography: .neon, includeAudio: false,
            reactiveProgram: program, reactiveSourceURL: nil)
    }

    func testOffAndMissingTimelinePreserveOriginalShader() throws {
        let timeline = audioTimeline()
        let requestOff = try request(reaction: .off)
        let requestOn = try request()
        for seconds in [0.0, 1.05, 1.20, 2.0] {
            let frame = StoryRenderTimeline(
                request: requestOn, profile: .balanced).frame(at: seconds)
            XCTAssertEqual(CreativeMarbleFrameResolver.resolve(
                program: requestOff.reactiveProgram, timeline: timeline,
                sourceTime: frame.sourceTime), .neutral)
            XCTAssertEqual(CreativeMarbleFrameResolver.resolve(
                program: requestOn.reactiveProgram, timeline: nil,
                sourceTime: frame.sourceTime), .neutral)
        }
    }

    func testScrubAndMP4ShareExactDistortionAtOriginalSourceTimestamp() throws {
        let request = try request()
        let features = audioTimeline()
        let timeline = StoryRenderTimeline(request: request, profile: .balanced)
        let index = 23 // 1.15 seconds into clip; at original source 3.15s
        let exportFrame = timeline.frame(index: index)
        let previewFrame = timeline.frame(at: Double(index) / 20)
        XCTAssertEqual(exportFrame, previewFrame)

        let preview = StorySceneView(
            request: request, artwork: nil,
            frame: previewFrame, visualTimeline: features)
        let exported = StorySceneView(
            request: request, artwork: nil,
            frame: exportFrame, visualTimeline: features)
        XCTAssertEqual(preview.reactiveDistortion,
                       exported.reactiveDistortion, accuracy: 1e-12)
        XCTAssertGreaterThan(preview.reactiveDistortion, 0)
        XCTAssertEqual(exportFrame.sourceTime, 3.15, accuracy: 0.00001)

        // Scrubbing out of order never advances a mutable visual phase.
        let first = CreativeMarbleFrameResolver.resolve(
            program: request.reactiveProgram, timeline: features,
            sourceTime: 3.15)
        _ = CreativeMarbleFrameResolver.resolve(
            program: request.reactiveProgram, timeline: features,
            sourceTime: 3.3)
        let repeated = CreativeMarbleFrameResolver.resolve(
            program: request.reactiveProgram, timeline: features,
            sourceTime: 3.15)
        XCTAssertEqual(first, repeated)
        XCTAssertEqual(first.marbleDistortion, exported.reactiveDistortion)
    }

    func testSilenceAndOutOfTimelineReturnNeutral() throws {
        let program = try XCTUnwrap(request().reactiveProgram)
        let timeline = audioTimeline()
        for sourceTime in [-2.0, 0.5, 3.35, 15.0, .nan, .infinity] {
            let frame = CreativeMarbleFrameResolver.resolve(
                program: program, timeline: timeline, sourceTime: sourceTime)
            XCTAssertEqual(frame, .neutral)
        }
    }

    func testBeatEquationUsesFixedSourceWindowAfterForwardAndBackwardSeek() throws {
        let preset = try XCTUnwrap(request().reactiveProgram).preset
        let program = CreativeVisualProgram(preset: preset, rules: [
            CreativeParameterRule(
                target: .marbleDistortion,
                equation: CreativeEquation(signal: .beat))
        ])
        let onset = AudioFeatures(bass: 0.85, energy: 0.8, beatDetected: true)
        let timeline = AudioFeatureTimeline(points: [
            AudioFeaturePoint(time: 0, features: strong),
            AudioFeaturePoint(time: 3, features: onset),
            AudioFeaturePoint(time: 3.05, features: strong)
        ], duration: 20)
        // At 3.1 the current envelope no longer has a beat flag. The fixed
        // look-back must feed BOTH the base mapper and the typed equation.
        XCTAssertFalse(timeline.features(at: 3.1).beatDetected)
        for time in [3.1, 10, 3.1, 3.2, 2, 3.1] {
            let frame = CreativeMarbleFrameResolver.resolve(
                program: program, timeline: timeline, sourceTime: time)
            XCTAssertEqual(frame.marbleDistortion, time == 3.1 ? 1 : 0)
        }
    }

    func testSourceClockMatchesLiveParametersAtEveryExportSpeedAndProfile() throws {
        let features = audioTimeline()
        for speed in [Float(0.75), 1, 1.5] {
            for id in CreativePresetCatalog.all.map(\.id) {
                let request = try request(id: id, speed: speed, lyricOffset: 0.4)
                for profile in [StoryEncodingProfile.economical, .balanced] {
                    let timeline = StoryRenderTimeline(request: request, profile: profile)
                    for index in [0, 4, 8, 12, 16, 20] {
                        let video = timeline.frame(index: index)
                        let preview = timeline.frame(at: video.elapsed)
                        let expectedTime = 2 + Double(index) / Double(profile.fps) * Double(speed)
                        XCTAssertEqual(video.sourceTime, expectedTime, accuracy: 1e-12)
                        XCTAssertEqual(video.lyricTime, expectedTime + 0.4, accuracy: 1e-12)
                        let live = CreativeMarbleFrameResolver.resolve(
                            program: request.reactiveProgram, timeline: features,
                            sourceTime: expectedTime)
                        for frame in [preview, video] {
                            let scene = StorySceneView(
                                request: request, artwork: nil,
                                frame: frame, visualTimeline: features)
                            XCTAssertEqual(scene.reactiveDistortion, live.marbleDistortion,
                                           accuracy: 1e-12)
                        }
                    }
                }
            }
        }
    }

    func testReactionIntensityAndAllSeventeenThemesRemainBounded() {
        let timeline = audioTimeline()
        for theme in AppTheme.allCases {
            for mode in [CreativePreset.AudioReaction.subtle, .responsive] {
                let program = CreativePresetCatalog.effectiveProgram(
                    id: "bass-pulse", theme: theme, typography: .neon,
                    background: .turbulent, reaction: mode)
                let frame = CreativeMarbleFrameResolver.resolve(
                    program: program, timeline: timeline, sourceTime: 3.15)
                XCTAssertTrue((0...1).contains(frame.marbleDistortion),
                              "Theme: \(theme.rawValue)")
            }
        }
        let subtle = CreativePresetCatalog.effectiveProgram(
            id: "bass-pulse", theme: .acid, typography: .neon,
            background: .turbulent, reaction: .subtle)
        let responsive = CreativePresetCatalog.effectiveProgram(
            id: "bass-pulse", theme: .acid, typography: .neon,
            background: .turbulent, reaction: .responsive)
        XCTAssertLessThan(
            CreativeMarbleFrameResolver.resolve(
                program: subtle, timeline: timeline,
                sourceTime: 3.15).marbleDistortion,
            CreativeMarbleFrameResolver.resolve(
                program: responsive, timeline: timeline,
                sourceTime: 3.15).marbleDistortion)
    }

    @MainActor
    func testMetalFrameRasterSizesUnchangedWhenReactive() throws {
        let request = try request()
        let profile = StoryEncodingProfile.economical
        let frame = StoryRenderTimeline(request: request,
                                         profile: profile).frame(at: 1.15)
        let image = try StoryFrameRenderer.render(
            request: request, artwork: nil, frame: frame,
            profile: profile, visualTimeline: audioTimeline())
        XCTAssertEqual(image.width, profile.width)
        XCTAssertEqual(image.height, profile.height)
        XCTAssertLessThan(image.width, image.height)
    }

    func testCachedTimelineBelongsOnlyToMatchingSourceURL() async {
        let engine = AudioFeatureEngine()
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("marble-test.caf")
        let cached = await engine.cachedTimeline(for: url)
        XCTAssertNil(cached)
        await engine.reset()
    }
}
