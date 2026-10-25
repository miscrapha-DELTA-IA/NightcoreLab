import Foundation
import XCTest
@testable import NightcoreLab

final class GeneratedLyricsFallbackTests: XCTestCase {
    func testLanguageChoiceIsExplicitRatherThanUnverifiedLanguageDetection() {
        XCTAssertEqual(AutoLyricsTranscriber.recognitionLocale(
            preference: "pt-BR", system: Locale(identifier: "en-US")).identifier, "pt_BR")
        XCTAssertEqual(AutoLyricsTranscriber.recognitionLocale(
            preference: "en-US", system: Locale(identifier: "pt-BR")).identifier, "en_US")
        XCTAssertEqual(AutoLyricsTranscriber.recognitionLocale(
            preference: "es-ES", system: Locale(identifier: "en-US")).identifier, "es_ES")
        XCTAssertEqual(AutoLyricsTranscriber.recognitionLocale(
            preference: "system", system: Locale(identifier: "fr-FR")).identifier, "fr_FR")
    }

    func testRecognizedWordsAreMarkedAsGeneratedAndNeedReview() {
        let words = [
            AutoLyricsTranscriber.TimedWord(text: "Hello", start: 3, end: 3.6),
            AutoLyricsTranscriber.TimedWord(text: "world", start: 3.7, end: 4.4)
        ]
        let lines = AutoLyricsTranscriber.group(words, bars: [])
        XCTAssertEqual(lines.count, 1)
        XCTAssertEqual(lines.first?.words.map(\.text), ["Hello", "world"])
        XCTAssertEqual(lines.first?.provenance, .autoTranscribed)
    }

    func testNoSpeechCannotFabricateLyricsWords() {
        let cues = AutoLyricsTranscriber.guide(recognizedWords: nil,
            vocalURL: URL(fileURLWithPath: "/file-does-not-exist.caf"),
            duration: 16, bars: [0, 4, 8, 12])
        XCTAssertFalse(cues.isEmpty)
        XCTAssertTrue(cues.allSatisfy { $0.provenance == .rhythmicCue })
        XCTAssertTrue(cues.allSatisfy { $0.words.map(\.text) == ["♪"] })
    }

    @MainActor
    func testManualTranscriptionWithoutAudioDoesNotAskPermissionOrChangeSong() async {
        let store = LyricsStore()
        store.beginLoading(trackID: "track-a")
        let result = await store.transcribeCurrentAudio(sourceURL: nil, duration: 180)
        XCTAssertEqual(result, .missingAudio)
        XCTAssertEqual(store.trackID, "track-a")
        XCTAssertTrue(store.lines.isEmpty)
        XCTAssertEqual(store.status, .searching)
    }

    func testGenerationMessagesDistinguishWordsAndRhythmGuide() {
        XCTAssertTrue(AudioLyricsGenerationOutcome.generatedWords.message
            .contains("estimado"))
        XCTAssertTrue(AudioLyricsGenerationOutcome.rhythmicOnly.message
            .contains("guia rítmico"))
    }
}
