import Foundation
import SwiftUI
import XCTest
@testable import NightcoreLab

final class CompositionRuntimeTests: XCTestCase {
    private let pulse = AudioFeatures(
        bass: 0.84, mid: 0.42, treble: 0.18, energy: 0.72,
        beatDetected: true)

    private func timeline() -> AudioFeatureTimeline {
        AudioFeatureTimeline(points: [
            AudioFeaturePoint(time: 0, features: .silent),
            AudioFeaturePoint(time: 2.0, features: pulse),
            AudioFeaturePoint(time: 2.2, features: pulse),
            AudioFeaturePoint(time: 2.5, features: pulse),
            AudioFeaturePoint(time: 2.7, features: .silent),
            AudioFeaturePoint(time: 4, features: .silent)
        ], duration: 5)
    }

    private func request(id: String = "bass-pulse", speed: Float = 1,
                         sourceStart: Double = 1.5,
                         reaction: CreativePreset.AudioReaction = .responsive)
        throws -> StoryVideoRequest {
        let track = TrackInfo(
            track: Track(id: "12345678901", title: "Runtime Check",
                         thumbnailURL: nil, cleanArtist: "Test Artist"),
            fileName: nil, coverURL: nil)
        let program = CreativePresetCatalog.effectiveProgram(
            id: id, theme: .acid, typography: .neon,
            background: .turbulent, reaction: reaction)
        return try StoryRequestBuilder.make(
            mode: .player, track: track, theme: .acid,
            playerStyle: .turbulent, karaokeBackground: .marble,
            marblePhase: 9, playbackTime: sourceStart, sourceDuration: 20,
            speed: speed, lines: [], lyricOffset: 0.3,
            typography: .neon, includeAudio: false,
            reactiveProgram: program, reactiveSourceURL: nil)
    }

    func testSameInputAndTimestampAlwaysProduceIdenticalFrame() throws {
        let request = try request()
        let composition = try XCTUnwrap(request.visualComposition)
        let runtime = CompositionRuntime(composition: composition)
        let audio = timeline()
        let first = try XCTUnwrap(runtime.frame(at: 0.65, audioTimeline: audio))
        _ = runtime.frame(at: 2.5, audioTimeline: audio)
        let third = try XCTUnwrap(runtime.frame(at: 0.65, audioTimeline: audio))
        XCTAssertEqual(first, third)
        XCTAssertEqual(first, CompositionFrameResolver.resolve(
            composition, elapsed: 0.65,
            features: CompositionAudioSampler.sample(audio, at: 2.15)))
        XCTAssertEqual(first.timestamp.elapsed, 0.65, accuracy: 1e-12)
        XCTAssertEqual(first.timestamp.sourceTime, 2.15, accuracy: 1e-12)
    }

    func testPreviewAndExportShareSameResolvedFrameAndExistingScene() throws {
        let request = try request()
        let composition = try XCTUnwrap(request.visualComposition)
        let audio = timeline()
        for profile in [StoryEncodingProfile.balanced, .economical] {
            let grid = StoryRenderTimeline(request: request, profile: profile)
            for index in [0, 5, 11, 20, 30] {
                let exportFrame = grid.frame(index: index)
                let scrubFrame = grid.frame(at: exportFrame.elapsed)
                XCTAssertEqual(exportFrame, scrubFrame)
                let previewResolved = CompositionRuntime(composition: composition)
                    .frame(at: scrubFrame.elapsed, audioTimeline: audio)
                let preview = StorySceneView(
                    request: request, artwork: nil, frame: scrubFrame,
                    visualTimeline: audio, resolvedCompositionFrame: previewResolved)
                let exported = StorySceneView(
                    request: request, artwork: nil, frame: exportFrame,
                    visualTimeline: audio)
                XCTAssertEqual(preview.resolvedCompositionFrame,
                               exported.resolvedCompositionFrame)
                XCTAssertEqual(preview.reactiveDistortion,
                               exported.reactiveDistortion, accuracy: 1e-12)
                XCTAssertEqual(preview.reactiveDistortion,
                    ResolvedFrameRendererAdapter.marbleDistortion(from: previewResolved),
                    accuracy: 1e-12)
            }
        }
    }

    func testMissingTimelineAndSilencePreserveNeutralBaseLayerValues() throws {
        let request = try request()
        let comp = try XCTUnwrap(request.visualComposition)
        let runtime = CompositionRuntime(composition: comp)
        let noAudio = try XCTUnwrap(runtime.frame(at: 0.8, audioTimeline: nil))
        let silence = try XCTUnwrap(runtime.frame(at: 0.8, features: .silent))
        XCTAssertEqual(noAudio, silence)
        XCTAssertEqual(noAudio.programParameters, .neutral)
        XCTAssertEqual(ResolvedFrameRendererAdapter.marbleDistortion(from: noAudio), 0)
        for layer in noAudio.layers {
            XCTAssertEqual(layer.value(for: .opacity), 1)
            XCTAssertEqual(layer.value(for: .intensity), 1)
        }
        // Invalid/out-of-range source timestamp is not extrapolated into a beat.
        let outside = try XCTUnwrap(runtime.frame(at: 10, audioTimeline: timeline()))
        XCTAssertEqual(outside.programParameters, .neutral)
    }

    func testPlaybackRateKeepsElapsedAndSourceTimeIndependent() throws {
        let features = timeline()
        for speed in [Float(0.75), 1, 1.5] {
            let request = try self.request(speed: speed)
            let composition = try XCTUnwrap(request.visualComposition)
            let runtime = CompositionRuntime(composition: composition)
            let grid = StoryRenderTimeline(request: request, profile: .balanced)
            for i in [0, 5, 20, 35] {
                let story = grid.frame(index: i)
                let frame = try XCTUnwrap(runtime.frame(
                    at: story.elapsed, audioTimeline: features))
                XCTAssertEqual(frame.timestamp.elapsed, story.elapsed)
                XCTAssertEqual(frame.timestamp.sourceTime,
                               story.sourceTime, accuracy: 1e-12)
                XCTAssertEqual(frame.timestamp.sourceTime,
                               1.5 + story.elapsed * Double(speed), accuracy: 1e-12)
            }
        }
    }

    func testCurrentPresetsMatchLegacyMarbleForEverySourceTimestamp() throws {
        let audio = timeline()
        for id in CreativePresetCatalog.all.map(\.id) {
            for reaction in [CreativePreset.AudioReaction.responsive, .subtle, .off] {
                let request = try self.request(id: id, reaction: reaction)
                let program = try XCTUnwrap(request.reactiveProgram)
                let runtime = CompositionRuntime(
                    composition: try XCTUnwrap(request.visualComposition))
                for elapsed in [0, 0.4, 0.65, 1, 1.25, 1.7, 2.5, 4, 7] {
                    let sourceTime = request.sourceTime(at: elapsed)
                    let expected = CreativeMarbleFrameResolver.resolve(
                        program: program, timeline: audio, sourceTime: sourceTime)
                    let resolved = runtime.frame(at: elapsed, audioTimeline: audio)
                    let adapted = ResolvedFrameRendererAdapter.marbleParameters(
                        from: resolved)
                    XCTAssertEqual(adapted, expected,
                        "\(id)/\(reaction)/elapsed=\(elapsed)")
                }
            }
        }
    }

    func testSourceOnsetWindowMatchesPreviousMarbleBeatLogic() throws {
        let program = CreativePresetCatalog.effectiveProgram(
            id: "bass-pulse", theme: .acid, typography: .neon,
            background: .turbulent, reaction: .responsive)
        let beatProgram = CreativeVisualProgram(preset: program.preset, rules: [
            CreativeParameterRule(target: .marbleDistortion,
                equation: CreativeEquation(signal: .beat))
        ])
        let composition = try XCTUnwrap(CompositionRuntime.freeze(
            program: beatProgram, sourceStart: 3, speed: 1, duration: 3))
        let audio = AudioFeatureTimeline(points: [
            AudioFeaturePoint(time: 0, features: pulse),
            AudioFeaturePoint(time: 3, features: pulse),
            AudioFeaturePoint(time: 3.05, features: AudioFeatures(
                bass: 0.8, energy: 0.8, beatDetected: false)),
            AudioFeaturePoint(time: 3.4, features: .silent)
        ], duration: 6)
        let runtime = CompositionRuntime(composition: composition)
        for elapsed in [0.1, 1, 0.1, 0.3, 2, 0.1] {
            let now = 3 + elapsed
            let expected = CreativeMarbleFrameResolver.resolve(
                program: beatProgram, timeline: audio, sourceTime: now)
            let frame = try XCTUnwrap(runtime.frame(at: elapsed, audioTimeline: audio))
            XCTAssertEqual(frame.programParameters, expected)
        }
    }

    func testMismatchedInjectedPreviewFrameIsRejected() throws {
        let request = try self.request()
        let audio = timeline()
        let grid = StoryRenderTimeline(request: request, profile: .balanced)
        let incorrect = try XCTUnwrap(CompositionRuntime(
            composition: XCTUnwrap(request.visualComposition))
            .frame(at: 2, audioTimeline: audio))
        let storyFrame = grid.frame(at: 1)
        let scene = StorySceneView(
            request: request, artwork: nil, frame: storyFrame,
            visualTimeline: audio, resolvedCompositionFrame: incorrect)
        let recomputed = try XCTUnwrap(CompositionRuntime(
            composition: XCTUnwrap(request.visualComposition))
            .frame(at: storyFrame.elapsed, audioTimeline: audio))
        XCTAssertEqual(scene.resolvedCompositionFrame, recomputed)
        XCTAssertNotEqual(scene.resolvedCompositionFrame, incorrect)
    }

    func testUnconfiguredCompositionPreservesNonReactiveExportPath() throws {
        let track = TrackInfo(
            track: Track(id: "12345678901", title: "Unreactive",
                         thumbnailURL: nil, cleanArtist: "Artist"),
            fileName: nil, coverURL: nil)
        let request = try StoryRequestBuilder.make(
            mode: .player, track: track, theme: .noir,
            playerStyle: .blurred, karaokeBackground: .marble,
            marblePhase: 3, playbackTime: 1, sourceDuration: 10,
            speed: 1, lines: [], lyricOffset: 0,
            typography: .neon, includeAudio: false)
        // Since the 10A/10C integration a neutral composition is always frozen
        // (reaction .off): same neutral Marble, single runtime path.
        XCTAssertNotNil(request.visualComposition)
        XCTAssertEqual(request.visualComposition?.program.preset.audioReaction, .off)
        let frame = StoryRenderTimeline(
            request: request, profile: .balanced).frame(at: 1)
        let scene = StorySceneView(
            request: request, artwork: nil, frame: frame,
            visualTimeline: timeline())
        XCTAssertNotNil(scene.resolvedCompositionFrame)
        XCTAssertEqual(scene.reactiveDistortion, 0)
        XCTAssertEqual(scene.beatPulse, 0)
        // Direct requests without a frozen runtime no longer have a separate
        // legacy route: renderRuntime freezes one (neutral here) on demand.
        var direct = request
        direct.compositionRuntime = nil
        XCTAssertNotNil(direct.renderRuntime)
        let directScene = StorySceneView(
            request: direct, artwork: nil, frame: frame,
            visualTimeline: timeline())
        XCTAssertNotNil(directScene.resolvedCompositionFrame)
        XCTAssertEqual(directScene.reactiveDistortion, 0)
        XCTAssertEqual(directScene.beatPulse, 0)
        XCTAssertEqual(directScene.typographyFrame, scene.typographyFrame)
    }

    @MainActor
    func testExistingStoryFrameRendererReceivesCompatibleValues() throws {
        let request = try self.request()
        let audio = timeline()
        let profile = StoryEncodingProfile.economical
        let frame = StoryRenderTimeline(request: request, profile: profile)
            .frame(at: 0.65)
        let scene = StorySceneView(request: request, artwork: nil, frame: frame,
                                   visualTimeline: audio)
        let resolved = try XCTUnwrap(scene.resolvedCompositionFrame)
        XCTAssertEqual(scene.reactiveDistortion,
            resolved.programParameters.marbleDistortion, accuracy: 1e-12)
        let rendered = try StoryFrameRenderer.render(
            request: request, artwork: nil, frame: frame,
            profile: profile, visualTimeline: audio)
        XCTAssertEqual(rendered.width, profile.width)
        XCTAssertEqual(rendered.height, profile.height)
    }
}
