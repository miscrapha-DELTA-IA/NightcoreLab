import XCTest
@testable import NightcoreLab

final class DevStemFeedbackTests: XCTestCase {
    func testDemucsHTTPFailuresHaveActionableExplanations() {
        XCTAssertTrue(DevStemBackend.diagnostic(for: 401).contains("Token"))
        XCTAssertTrue(DevStemBackend.diagnostic(for: 429).contains("ocupado"))
        XCTAssertTrue(DevStemBackend.diagnostic(for: 502).contains("Túnel"))
        XCTAssertTrue(DevStemBackend.diagnostic(for: 413).contains("35 MB"))
        XCTAssertTrue(DevStemBackend.diagnostic(for: 404).contains("URL raiz"))
    }

    @MainActor
    func testPrepareWithoutLoadedTrackExplainsWhyNothingHappened() {
        let audio = AudioEngineManager()
        audio.retryStemPreparation()
        XCTAssertEqual(audio.stemPreparationError,
                       "Selecione uma música antes de preparar os stems.")
        XCTAssertNil(audio.stemPreparationStatus)
        XCTAssertFalse(audio.stemsAvailable)
    }

    @MainActor
    func testCancellingAbsentJobCannotCreateAFalseSuccess() {
        let audio = AudioEngineManager()
        audio.cancelStemPreparation()
        XCTAssertNil(audio.stemPreparationStatus)
        XCTAssertFalse(audio.stemsAvailable)
    }

    func testDevicePanelExposesProgressAndSafeCancellation() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("NightcoreLab/Sources")
        let panel = try String(contentsOf: root.appendingPathComponent("StemMixerControls.swift"),
                               encoding: .utf8)
        XCTAssertTrue(panel.contains("stem.preparationStatus"))
        XCTAssertTrue(panel.contains("stem.cancelPreparation"))
        XCTAssertTrue(panel.contains(".disabled(audio.stemPreparationStatus != nil)"))
    }
}
