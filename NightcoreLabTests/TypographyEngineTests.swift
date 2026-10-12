import Foundation
import XCTest
@testable import NightcoreLab

final class TypographyEngineTests: XCTestCase {
    private func line(precision: LyricPrecision = .word) -> TimedLyricLine {
        TimedLyricLine(id: 7, start: 2, end: 6, words: [
            WordSync(id: 0, text: "HELLO", start: 2, end: 4, spaceAfter: true),
            WordSync(id: 1, text: "WORLD", start: 4, end: 6, spaceAfter: false)
        ], precision: precision)
    }

    private func state(_ status: TypographyLineStatus = .active,
                       precision: LyricPrecision = .word) -> LyricsState {
        LyricsState(line: line(precision: precision), status: status)
    }

    private func audio(beat: Bool = false, energy: Double = 0.7,
                       bass: Double = 0.5) -> AudioFeatures {
        AudioFeatures(bass: bass, mid: 0.25, energy: energy,
                      beatDetected: beat)
    }

    func testIdenticalWordsAndTimestampsAlwaysResolveIdentically() throws {
        let preset = TypographyPreset(style: .magazineCutout)
        let a = TypographyResolver.resolve(state(), at: 3,
            features: audio(), preset: preset)
        _ = TypographyResolver.resolve(state(), at: 5,
            features: audio(beat: true), preset: preset)
        let b = TypographyResolver.resolve(state(), at: 3,
            features: audio(), preset: preset)
        XCTAssertEqual(a, b)
        XCTAssertEqual(a.activeWordID, 0)
        XCTAssertEqual(a.word(id: 0)?.progress, 0.5)
        XCTAssertEqual(a.word(id: 1)?.progress, 0)
    }

    func testDifferentWordsAndEditedTextHaveDifferentStableSeeds() {
        let frame = TypographyResolver.resolve(state(), at: 3,
            features: nil, preset: TypographyPreset(style: .magazineCutout))
        XCTAssertNotEqual(frame.word(id: 0)?.seed, frame.word(id: 1)?.seed)
        let changed = WordSync(id: 0, text: "NEW", start: 2, end: 4,
                               spaceAfter: true)
        XCTAssertNotEqual(frame.word(id: 0)?.seed,
                          TypographyResolver.stableSeed(lineID: 7, word: changed))
        XCTAssertEqual(frame.word(id: 0)?.seed,
                       TypographyResolver.stableSeed(lineID: 7, word: line().words[0]))
    }

    func testPresetSelectionChangesOnlyPresentationAndKeepsWordFill() throws {
        let neon = TypographyResolver.resolve(state(), at: 3.25,
            features: nil, preset: .init(style: .neon))
        let magazine = TypographyResolver.resolve(state(), at: 3.25,
            features: nil, preset: .init(style: .magazineCutout))
        XCTAssertNotEqual(neon, magazine)
        XCTAssertEqual(neon.words.map(\.progress), magazine.words.map(\.progress))
        XCTAssertNil(neon.word(id: 0)?.magazine)
        XCTAssertNotNil(magazine.word(id: 0)?.magazine)
        XCTAssertEqual(neon.preset.legacyStyle, .neon)
        XCTAssertEqual(magazine.preset.legacyStyle, .magazineCutout)
        XCTAssertEqual(try JSONDecoder().decode(
            TypographyPreset.self, from: JSONEncoder().encode(magazine.preset)),
            magazine.preset)
    }

    func testMagazineAppearanceIsPixelContractCompatibleWithLegacy() {
        let magazine = TypographyResolver.resolve(state(), at: 3,
            features: nil, preset: .init(style: .magazineCutout))
        for (raw, resolved) in zip(line().words, magazine.words) {
            let legacy = KaraokeWordStyleResolver.resolve(lineID: 7, word: raw)
            XCTAssertEqual(resolved.magazine?.legacy, legacy)
            XCTAssertEqual(resolved.progress, raw.progress(at: 3))
        }
    }

    func testNoAudioKeepsBaseNeonAndMagazineUnchanged() {
        for style in [TypographyStyle.neon, .magazineCutout] {
            let preset = TypographyPreset(style: style)
            let missing = TypographyResolver.resolve(state(), at: 3,
                features: nil, preset: preset)
            let silence = TypographyResolver.resolve(state(), at: 3,
                features: .silent, preset: preset)
            let loud = TypographyResolver.resolve(state(), at: 3,
                features: audio(beat: true), preset: preset)
            XCTAssertEqual(missing, silence)
            XCTAssertEqual(missing, loud,
                "Legacy styles must ignore audio unless explicitly opted in")
            XCTAssertEqual(missing.word(id: 0)?.scale, 1)
            XCTAssertEqual(missing.word(id: 0)?.glowStrength, 1)
        }
    }

    func testBeatChangesOnlyOptedInScaleAndEnergyChangesOnlyGlow() throws {
        let preset = TypographyPreset(style: .neon, audioReaction: .responsive)
        let withoutBeat = TypographyResolver.resolve(state(), at: 3,
            features: audio(beat: false), preset: preset)
        let withBeat = TypographyResolver.resolve(state(), at: 3,
            features: audio(beat: true), preset: preset)
        XCTAssertEqual(withoutBeat.words.map(\.progress), withBeat.words.map(\.progress))
        XCTAssertEqual(withoutBeat.words.map(\.seed), withBeat.words.map(\.seed))
        XCTAssertEqual(withoutBeat.words.map(\.glowStrength),
                       withBeat.words.map(\.glowStrength))
        XCTAssertEqual(withoutBeat.word(id: 0)?.scale, 1)
        XCTAssertEqual(try XCTUnwrap(withBeat.word(id: 0)?.scale), 1.04, accuracy: 1e-12)

        let highEnergy = TypographyResolver.resolve(state(), at: 3,
            features: audio(energy: 1), preset: preset)
        XCTAssertEqual(highEnergy.words.map(\.scale), withoutBeat.words.map(\.scale))
        XCTAssertEqual(highEnergy.words.map(\.progress),
                       withoutBeat.words.map(\.progress))
        XCTAssertGreaterThan(try XCTUnwrap(highEnergy.word(id: 0)?.glowStrength),
                             try XCTUnwrap(withoutBeat.word(id: 0)?.glowStrength))
    }

    func testLinePrecisionDoesNotFakeWordProgress() {
        let active = TypographyResolver.resolve(
            state(.active, precision: .line), at: 2.5,
            features: nil, preset: .init(style: .neon))
        XCTAssertNil(active.activeWordID)
        XCTAssertEqual(active.words.map(\.progress), [1, 1])
        let past = TypographyResolver.resolve(state(.past), at: 3,
            features: nil, preset: .init(style: .neon))
        let upcoming = TypographyResolver.resolve(state(.upcoming), at: 3,
            features: nil, preset: .init(style: .neon))
        XCTAssertEqual(past.words.map(\.progress), [1, 1])
        XCTAssertEqual(upcoming.words.map(\.progress), [0, 0])
        XCTAssertTrue(TypographyResolver.resolve(
            LyricsState(line: TimedLyricLine(id: 8, start: 6, end: 7,
                        words: [], precision: .line), status: .active),
            at: 6.5, features: nil,
            preset: .init(style: .neon)).words.isEmpty)
    }

    func testCompositionOnlyAttachesTypographyToActiveMatchingLayer() throws {
        let program = CreativePresetCatalog.program(for: "original")
        let timeline = try CompositionTimeline(
            sourceStart: 2, playbackSpeed: 1.25, duration: 3)
        let composition = try CreativeSnapshotAdapter.wrap(
            program, timeline: timeline)
        let runtime = CompositionRuntime(composition: composition)
        let layer = TypographyLayer(
            state: state(), preset: .init(style: .magazineCutout),
            lyricOffset: 0.3)
        let withLyrics = try XCTUnwrap(runtime.frame(
            at: 0.8, audioTimeline: nil, typography: layer))
        XCTAssertEqual(try XCTUnwrap(withLyrics.typographyFrame?.lyricTime), 3.3, accuracy: 1e-12)
        XCTAssertEqual(withLyrics.typographyFrame?.lineID, 7)
        XCTAssertEqual(try XCTUnwrap(withLyrics.typographyFrame?.word(id: 0)?.progress),
                       0.65, accuracy: 1e-12)
        let without = try XCTUnwrap(runtime.frame(
            at: 0.8, audioTimeline: nil))
        XCTAssertNil(without.typographyFrame)
        XCTAssertEqual(without.programParameters, withLyrics.programParameters)
        XCTAssertEqual(without.layers, withLyrics.layers)

        let wrong = TypographyLayer(
            layerID: "missing", state: state(),
            preset: .init(style: .neon))
        XCTAssertNil(runtime.frame(
            at: 0.8, audioTimeline: nil, typography: wrong)?.typographyFrame)
    }

    private func storyRequest() throws -> StoryVideoRequest {
        let track = TrackInfo(
            track: Track(id: "12345678901", title: "Typography Test",
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

    func testPreviewAndExportObtainIdenticalTypographyFrame() throws {
        let request = try storyRequest()
        let composition = try XCTUnwrap(request.visualComposition)
        let grid = StoryRenderTimeline(
            request: request, profile: .balanced)
        let frame = grid.frame(index: 18)
        let layer = TypographyLayer.forStory(
            lines: request.lines, lyricTime: frame.lyricTime,
            lyricOffset: request.lyricOffset)
        let previewFrame = CompositionRuntime(composition: composition)
            .frame(at: frame.elapsed, audioTimeline: nil, typography: layer)
        let preview = StorySceneView(
            request: request, artwork: nil, frame: grid.frame(at: frame.elapsed),
            resolvedCompositionFrame: previewFrame)
        let export = StorySceneView(
            request: request, artwork: nil, frame: frame)
        XCTAssertEqual(preview.resolvedCompositionFrame,
                       export.resolvedCompositionFrame)
        XCTAssertEqual(preview.resolvedCompositionFrame?.typographyFrame,
                       export.resolvedCompositionFrame?.typographyFrame)
        XCTAssertNotNil(export.resolvedCompositionFrame?.typographyFrame)
        XCTAssertEqual(export.resolvedCompositionFrame?.typographyFrame?
                       .word(id: 0)?.progress,
                       line().words[0].progress(at: frame.lyricTime))
    }
}
