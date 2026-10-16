import Foundation
import XCTest
@testable import NightcoreLab

final class Stage41ExperienceTests: XCTestCase {
    private var sourceRoot: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("NightcoreLab/Sources")
    }

    func testSustainAwareWeightingPrioritizesHeldVowels() {
        let short = LyricsAlignmentRefiner.sustainWeight("to", phraseEnding: false)
        let shortPT = LyricsAlignmentRefiner.sustainWeight("de", phraseEnding: false)
        let sung = LyricsAlignmentRefiner.sustainWeight("beautiful", phraseEnding: true)
        XCTAssertEqual(short, 0.45, accuracy: 0.0001)
        XCTAssertEqual(shortPT, 0.45, accuracy: 0.0001)
        XCTAssertGreaterThan(sung, short * 4)
        XCTAssertGreaterThan(LyricsAlignmentRefiner.sustainWeight("love", phraseEnding: true),
                             LyricsAlignmentRefiner.sustainWeight("love", phraseEnding: false))
    }

    func testTwentyMillisecondVocalEnvelopeIsMonotonicAndNotSimplyLinear() {
        let data = (0...50).map { index -> (time: TimeInterval, value: Double) in
            (Double(index) * 0.020, index < 25 ? 0.01 : 0.95)
        }
        let curve = LyricsAlignmentRefiner.envelope(start: 0, end: 1, samples: data)
        let valid = try? XCTUnwrap(curve)
        XCTAssertNotNil(valid)
        guard let valid else { return }
        XCTAssertEqual(valid.first, 0)
        XCTAssertEqual(valid.last, 1)
        XCTAssertTrue(zip(valid, valid.dropFirst()).allSatisfy { $0 <= $1 })
        XCTAssertNotEqual(valid[valid.count / 2], 0.5, accuracy: 0.015)
        let sync = WordSync(id: 0, text: "love", start: 0, end: 1,
                            spaceAfter: true, vocalEnvelopeCurve: valid)
        XCTAssertNotEqual(sync.progressFill(at: 0.5), sync.progress(at: 0.5),
                          accuracy: 0.015)
        let original = WordSync(id: 0, text: "exact", start: 0, end: 1,
                                spaceAfter: false)
        XCTAssertEqual(original.progressFill(at: 0.5), 0.5)
    }

    func testInferredWordTimingGivesConnectingWordsShorterDuration() {
        let words = [
            WordSync(id: 0, text: "to", start: 0, end: 1, spaceAfter: true),
            WordSync(id: 1, text: "beautiful", start: 0, end: 1, spaceAfter: true)
        ]
        let line = TimedLyricLine(id: 1, start: 1, end: 6,
                                   words: words, precision: .line)
        let refined = LyricsAlignmentRefiner.refine([line])
        XCTAssertEqual(refined.first?.precision, .estimated)
        let result = refined[0].words
        XCTAssertLessThan(result[0].end - result[0].start,
                          result[1].end - result[1].start)
        XCTAssertEqual(result[0].start, 1)
        XCTAssertEqual(result[1].end, 6)
    }

    func testMicPermissionIsIndependentFromSpeechRecognition() {
        XCTAssertFalse(AudioEngineManager.shouldShowMicrophonePermissionError(.granted))
        XCTAssertTrue(AudioEngineManager.shouldShowMicrophonePermissionError(.denied))
        XCTAssertFalse(AudioEngineManager.shouldShowMicrophonePermissionError(.undetermined))
        let score = try? String(contentsOf: sourceRoot
            .appendingPathComponent("Karaoke/KaraokeScoreHUD.swift"))
        XCTAssertTrue(score?.contains("showsError && audio.microphonePermissionDenied") == true)
        let audio = try? String(contentsOf: sourceRoot
            .appendingPathComponent("AudioEngineManager.swift"))
        XCTAssertTrue(audio?.contains("input.inputFormat(forBus: 0)") == true)
    }

    func testScoreToggleLivesInKaraokeAndLegendaWithoutTouchingPlayback() throws {
        let karaoke = try String(contentsOf: sourceRoot
            .appendingPathComponent("KaraokeLyricsView.swift"))
        let settings = try String(contentsOf: sourceRoot
            .appendingPathComponent("LyricsControlCenter.swift"))
        XCTAssertTrue(karaoke.contains("@AppStorage(\"karaoke.showScoreHUD\")"))
        XCTAssertTrue(settings.contains("@AppStorage(\"karaoke.showScoreHUD\")"))
        XCTAssertTrue(karaoke.contains("if showScoreHUD"))
        XCTAssertTrue(karaoke.contains("karaoke.toggleScoreHUD"))
        XCTAssertTrue(settings.contains("Toggle(\"Mostrar Placar\""))
        XCTAssertTrue(karaoke.contains("store.startTracking()"))
    }

    func testCompactOfflineCacheAndFourIndependentSpectralOutputs() {
        XCTAssertEqual(TrackAudioCache.maxCachedTracks, 20)
        XCTAssertEqual(TrackAudioCache.maxDiskBytes, 100 * 1024 * 1024)
        XCTAssertEqual(TrackAudioCache.aacBitRate, 144_000)
        XCTAssertEqual(WienerStemSeparator.windowSize, 2048)
        XCTAssertEqual(WienerStemSeparator.hopSize, 512)
        XCTAssertEqual(WienerStemSeparator.overlap, 0.75)
        XCTAssertEqual(Set(StemKind.allCases), Set([.vocal, .drums, .bass, .instrumental]))
    }

    func testDevDemucsConnectionCanExplicitlyRetryWithoutReplacingAudioGraph() throws {
        let mixer = try String(contentsOf: sourceRoot
            .appendingPathComponent("StemMixerControls.swift"))
        let audio = try String(contentsOf: sourceRoot
            .appendingPathComponent("AudioEngineManager.swift"))
        let backend = try String(contentsOf: sourceRoot
            .appendingPathComponent("DevStemBackend.swift"))
        XCTAssertTrue(mixer.contains("stem.retryPreparation"))
        XCTAssertTrue(mixer.contains("audio.retryStemPreparation()"))
        XCTAssertTrue(mixer.contains("stem.preparationError"))
        XCTAssertTrue(audio.contains("func retryStemPreparation()"))
        XCTAssertTrue(audio.contains("if stemMixEnabled { setStemMixerEnabled(false) }"))
        XCTAssertTrue(backend.contains("0..<300"))
        XCTAssertTrue(backend.contains("Task.checkCancellation()"))
        XCTAssertTrue(backend.contains("StemServerFailure.failed"))
        XCTAssertFalse(mixer.contains("audio.retryStemPreparation()\n        .onChange"))
    }

    func testStoryUsesFullWidthKaraokeHeaderAndRetainsStage40ShaderContracts() throws {
        let story = try String(contentsOf: sourceRoot
            .appendingPathComponent("Share/StorySceneView.swift"))
        XCTAssertTrue(story.contains("karaokeStyleTrackHeader"))
        XCTAssertTrue(story.contains("thumbnailSize: 76, titleLineLimit: 4"))
        XCTAssertTrue(story.contains("story.karaokeTrackHeader"))
        XCTAssertTrue(story.contains("NightcoreBrandLockup"))
        let shader = try String(contentsOf: sourceRoot
            .deletingLastPathComponent().appendingPathComponent("Resources/Shaders.metal"))
        XCTAssertTrue(shader.contains("kernel void storyTexturedMarbleFrame"))
        XCTAssertTrue(shader.contains("static inline half4 evaluateTexturedMarbleExport"))
    }
}
