import Foundation
import SwiftUI
import UIKit
import XCTest
@testable import NightcoreLab

final class TypographyAnimationEngineTests: XCTestCase {
    private func line() -> TimedLyricLine {
        TimedLyricLine(id: 17, start: 2, end: 6, words: [
            WordSync(id: 0, text: "NEON", start: 2, end: 4, spaceAfter: true),
            WordSync(id: 1, text: "MUSIC", start: 4, end: 6, spaceAfter: false)
        ], precision: .word)
    }

    private func frame(
        _ style: TypographyStyle, time: Double = 2.8,
        reaction: TypographyAudioReaction = .off,
        intensity: Double? = nil, seed: UInt64 = 5,
        features: AudioFeatures? = nil
    ) -> TypographyFrame {
        let preset = TypographyPreset(
            style: style, audioReaction: reaction,
            effectIntensity: intensity, deterministicSeed: seed)
        return TypographyResolver.resolve(
            LyricsState(line: line(), status: .active),
            at: time, features: features, preset: preset)
    }

    private func audio(beat: Bool = false, energy: Double = 0.65,
                       bass: Double = 0.45) -> AudioFeatures {
        AudioFeatures(bass: bass, mid: 0.2, energy: energy,
                      beatDetected: beat)
    }

    func testSameTimestampIsExactlyDeterministicEvenWhenSeekOrderChanges() {
        for style in TypographyStyle.allCases {
            let a = frame(style, time: 3.175, features: audio(beat: true))
            _ = frame(style, time: 5.92, features: audio())
            let b = frame(style, time: 3.175, features: audio(beat: true))
            XCTAssertEqual(a, b, "\(style)")
            XCTAssertEqual(a.animations.count, a.words.count)
            XCTAssertTrue(a.animations.values.allSatisfy(\.isValid))
        }
    }

    func testBeatOnlyChangesMappedScaleAndDoesNotChangeWordSync() throws {
        let before = frame(.kinetic, time: 2.4, reaction: .responsive,
                           features: audio(beat: false))
        let onBeat = frame(.kinetic, time: 2.4, reaction: .responsive,
                           features: audio(beat: true))
        let a = try XCTUnwrap(before.animation(for: 0))
        let b = try XCTUnwrap(onBeat.animation(for: 0))
        XCTAssertGreaterThan(b.scale, a.scale)
        XCTAssertEqual(a.opacity, b.opacity)
        XCTAssertEqual(a.offsetX, b.offsetX)
        XCTAssertEqual(a.offsetY, b.offsetY)
        XCTAssertEqual(a.rotation, b.rotation)
        XCTAssertEqual(a.glow, b.glow)
        XCTAssertEqual(a.chromaticOffset, b.chromaticOffset)
        XCTAssertEqual(before.words.map(\.progress), onBeat.words.map(\.progress))
        XCTAssertEqual(before.words.map(\.seed), onBeat.words.map(\.seed))
    }

    func testLegacyNeonHasSameIdentityTransformAndGlow() throws {
        for time in [2.0, 2.75, 3.5, 4.75, 5.9] {
            let neon = frame(.neon, time: time)
            for word in neon.words {
                let animation = try XCTUnwrap(neon.animation(for: word.id))
                XCTAssertTrue(animation.isTransformNeutral)
                XCTAssertEqual(animation.opacity, 1)
                XCTAssertEqual(animation.scale, word.scale)
                XCTAssertEqual(animation.rotation, 0)
                XCTAssertEqual(animation.glow, word.glowStrength)
                XCTAssertEqual(animation.effectIntensity, 0)
                XCTAssertEqual(animation.chromaticOffset, 0)
                XCTAssertEqual(word.progress, word.word.progress(at: time))
            }
        }
    }

    func testMagazineZeroIntensityRetainsExactLegacyTileDecisions() throws {
        let words = line().words
        for status in [TypographyLineStatus.past, .active, .upcoming] {
            let preset = TypographyPreset(style: .magazineCutout)
            let resolved = TypographyResolver.resolve(
                LyricsState(line: line(), status: status),
                at: 3, features: nil, preset: preset)
            for (word, result) in zip(words, resolved.words) {
                let actual = try XCTUnwrap(resolved.animation(for: word.id))
                let appearance = KaraokeWordStyleResolver.resolve(lineID: 17, word: word)
                let active = status == .active ||
                    (status == .upcoming && result.progress > 0.1)
                XCTAssertEqual(result.magazine?.legacy, appearance)
                XCTAssertEqual(actual.rotation, appearance.rotation)
                XCTAssertEqual(actual.scale, active ? 1.035 : 1)
                XCTAssertEqual(actual.opacity,
                               status == .past ? 0.5 : (active ? 1 : 0.68))
                XCTAssertEqual(actual.magazineToneIndex,
                               active ? MagazineCutoutTone.black.rawValue :
                                   appearance.tone.rawValue)
                XCTAssertEqual(actual.magazineFillEnabled,
                               active && result.progress > 0)
                XCTAssertEqual(actual.effectIntensity, 0)
            }
        }
    }

    func testMagazineIntensityChangesOnlyBoundedStyleParameters() throws {
        let baseline = frame(.magazineCutout, intensity: 0)
        let strong = frame(.magazineCutout, intensity: 1)
        let before = try XCTUnwrap(baseline.animation(for: 0))
        let after = try XCTUnwrap(strong.animation(for: 0))
        XCTAssertNotEqual(before.scale, after.scale)
        XCTAssertGreaterThanOrEqual(abs(after.rotation), abs(before.rotation))
        XCTAssertTrue(after.isValid)
        XCTAssertEqual(baseline.words.map(\.progress), strong.words.map(\.progress))
        XCTAssertEqual(baseline.words.map(\.seed), strong.words.map(\.seed))
        XCTAssertEqual(baseline.word(id: 0)?.magazine,
                       strong.word(id: 0)?.magazine)
    }

    func testGlitchRGBSplitAndFlickerRemainBoundedAndRepeatable() throws {
        for t in stride(from: 2.0, through: 3.0, by: 0.037) {
            let result = frame(.glitch, time: t, intensity: 1, seed: 4_278)
            let animation = try XCTUnwrap(result.animation(for: 0))
            XCTAssertTrue(animation.isValid)
            XCTAssertLessThanOrEqual(abs(animation.offsetX), 0.045 + 1e-12)
            XCTAssertLessThanOrEqual(animation.chromaticOffset, 0.015 + 1e-12)
            XCTAssertLessThanOrEqual(abs(animation.opacityVariation), 0.18 + 1e-12)
            XCTAssertEqual(animation.opacity,
                           1 + animation.opacityVariation, accuracy: 1e-12)
        }
        let a = frame(.glitch, time: 2.17, seed: 50)
        let b = frame(.glitch, time: 2.17, seed: 51)
        XCTAssertNotEqual(a.animation(for: 0), b.animation(for: 0))
    }

    func testMinimalHasLowerEffectIntensityThanKineticOrGlitch() throws {
        let minimal = try XCTUnwrap(frame(.minimal, intensity: 1).animation(for: 0))
        let kinetic = try XCTUnwrap(frame(.kinetic, intensity: 1).animation(for: 0))
        let glitch = try XCTUnwrap(frame(.glitch, intensity: 1).animation(for: 0))
        XCTAssertLessThan(minimal.effectIntensity, kinetic.effectIntensity)
        XCTAssertLessThan(minimal.effectIntensity, glitch.effectIntensity)
        XCTAssertEqual(minimal.offsetX, 0)
        XCTAssertEqual(minimal.offsetY, 0)
        XCTAssertEqual(minimal.scale, 1)
        XCTAssertEqual(minimal.blur, 0)
    }

    func testMissingAudioPreservesBaseEffectsAndReactionDisabledIsStable() throws {
        for style in TypographyStyle.allCases {
            let nilFeatures = frame(style, time: 3.22, features: nil)
            let loud = frame(style, time: 3.22,
                             features: audio(beat: true, energy: 1, bass: 1))
            XCTAssertEqual(nilFeatures, loud)
            XCTAssertTrue(nilFeatures.animations.values.allSatisfy(\.isValid))
        }
        let input = TypographyPreset(style: .kinetic, audioReaction: .responsive)
        XCTAssertTrue(input.audioMapping.isValid)
        XCTAssertNotEqual(
            frame(.kinetic, reaction: .responsive, features: nil).animations,
            frame(.kinetic, reaction: .responsive,
                  features: audio(beat: true)).animations)
    }

    func testAudioMappingIsTypedAndMissingFieldsDecodeLegacyJSON() throws {
        let old = Data(#"{"style":"neon","audioReaction":"responsive"}"#.utf8)
        let legacy = try JSONDecoder().decode(TypographyPreset.self, from: old)
        XCTAssertEqual(legacy.audioMapping, .legacy)
        XCTAssertEqual(legacy.effectIntensity, 0)
        XCTAssertEqual(legacy.deterministicSeed, 0)
        XCTAssertEqual(try JSONDecoder().decode(
            TypographyPreset.self, from: JSONEncoder().encode(legacy)), legacy)
        let invalid = Data(#"{"style":"neon","audioReaction":"off","effectIntensity":99}"#.utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(
            TypographyPreset.self, from: invalid))
        let invalidMapping = TypographyAudioMapping(bindings: [
            .init(signal: .beat, target: .scale, gain: 1)
        ])
        XCTAssertFalse(invalidMapping.isValid)
    }

    private func request() throws -> StoryVideoRequest {
        let track = TrackInfo(
            track: Track(id: "12345678901", title: "Effects",
                         thumbnailURL: nil, cleanArtist: "Nightcore"),
            fileName: nil, coverURL: nil)
        let program = CreativePresetCatalog.effectiveProgram(
            id: "bass-pulse", theme: .acid, typography: .neon,
            background: .turbulent, reaction: .responsive)
        return try StoryRequestBuilder.make(
            mode: .lyrics, track: track, theme: .acid,
            playerStyle: .turbulent, karaokeBackground: .marble,
            marblePhase: 5, playbackTime: 1.5, sourceDuration: 10,
            speed: 1.5, lines: [line()], lyricOffset: 0.3,
            typography: .classic, includeAudio: false,
            reactiveProgram: program, reactiveSourceURL: nil)
    }

    func testPreviewAndExportCarryExactlyTheSameAnimationState() throws {
        let request = try self.request()
        let composition = try XCTUnwrap(request.visualComposition)
        let grid = StoryRenderTimeline(request: request, profile: .balanced)
        for index in [9, 18, 30, 45] {
            let renderFrame = grid.frame(index: index)
            let layer = TypographyLayer.forStory(
                lines: request.lines, lyricTime: renderFrame.lyricTime,
                lyricOffset: request.lyricOffset)
            let preview = StorySceneView(
                request: request, artwork: nil,
                frame: grid.frame(at: renderFrame.elapsed),
                resolvedCompositionFrame: CompositionRuntime(
                    composition: composition).frame(
                    at: renderFrame.elapsed, audioTimeline: nil, typography: layer))
            let export = StorySceneView(
                request: request, artwork: nil, frame: renderFrame)
            XCTAssertEqual(
                preview.resolvedCompositionFrame?.typographyFrame?.animations,
                export.resolvedCompositionFrame?.typographyFrame?.animations)
            XCTAssertEqual(
                preview.resolvedCompositionFrame?.typographyFrame,
                export.resolvedCompositionFrame?.typographyFrame)
        }
    }

    @MainActor
    func testNeonLiveRendererWithNeutralAnimationMatchesLegacyPixels() throws {
        let word = line().words[0]
        let theme = KaraokeTheme.acid
        let resolved = frame(.neon, time: 3)
        let animation = try XCTUnwrap(resolved.animation(for: 0))
        let old = KaraokeWordView(
            word: word, fill: 0.5, fillColor: theme.fill, glow: true,
            theme: theme, maxWordWidth: 300, fontSize: 30,
            typographyStyle: .neon, magazineAppearance: nil,
            isCurrentLine: true, isPastLine: false)
        let new = KaraokeWordView(
            word: word, fill: 0.5, fillColor: theme.fill, glow: true,
            theme: theme, maxWordWidth: 300, fontSize: 30,
            typographyStyle: .neon, magazineAppearance: nil,
            isCurrentLine: true, isPastLine: false, animation: animation)
        func rendered<V: View>(_ view: V) throws -> Data {
            let renderer = ImageRenderer(content: view)
            renderer.proposedSize = ProposedViewSize(width: 300, height: 85)
            renderer.scale = 2
            return try XCTUnwrap(renderer.uiImage?.pngData())
        }
        XCTAssertEqual(try rendered(old), try rendered(new))
    }

    @MainActor
    func testMagazineLiveRendererWithNeutralIntensityMatchesLegacyPixels() throws {
        let word = line().words[0]
        let theme = KaraokeTheme.acid
        let resolved = frame(.magazineCutout, time: 3)
        let state = try XCTUnwrap(resolved.animation(for: 0))
        let appearance = try XCTUnwrap(resolved.word(id: 0)?.magazine?.legacy)
        let old = KaraokeWordView(
            word: word, fill: 0.5, fillColor: theme.fill, glow: true,
            theme: theme, maxWordWidth: 300, fontSize: 30,
            typographyStyle: .magazineCutout, magazineAppearance: appearance,
            isCurrentLine: true, isPastLine: false)
        let new = KaraokeWordView(
            word: word, fill: 0.5, fillColor: theme.fill, glow: true,
            theme: theme, maxWordWidth: 300, fontSize: 30,
            typographyStyle: .magazineCutout, magazineAppearance: appearance,
            isCurrentLine: true, isPastLine: false, animation: state)
        func rendered<V: View>(_ view: V) throws -> Data {
            let renderer = ImageRenderer(content: view)
            renderer.proposedSize = ProposedViewSize(width: 300, height: 85)
            renderer.scale = 2
            return try XCTUnwrap(renderer.uiImage?.pngData())
        }
        XCTAssertEqual(try rendered(old), try rendered(new))
    }
}
