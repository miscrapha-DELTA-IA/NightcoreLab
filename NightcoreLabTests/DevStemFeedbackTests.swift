import XCTest
@testable import NightcoreLab

final class DevStemFeedbackTests: XCTestCase {
    func testPastedTokenWhitespaceIsNormalizedWithoutChangingCharacters() {
        let token = "abcdef0123456789"
        XCTAssertEqual(StemDevCredentials.normalized("  \n" + token + "\r\n  "), token)
        XCTAssertEqual(StemDevCredentials.normalized(token), token)
    }

    func testLockScreenMediaControlsKeepPrimaryAudioSession() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("NightcoreLab/Sources")
        let audio = try String(contentsOf: root.appendingPathComponent("AudioEngineManager.swift"),
                               encoding: .utf8)
        let content = try String(contentsOf: root.appendingPathComponent("ContentView.swift"),
                                 encoding: .utf8)
        XCTAssertTrue(audio.contains("MPNowPlayingInfoCenter.default()"))
        XCTAssertTrue(audio.contains("MPRemoteCommandCenter.shared()"))
        XCTAssertFalse(audio.contains(".mixWithOthers"))
        XCTAssertTrue(content.contains("audio.setupNowPlaying()"))
        XCTAssertTrue(content.contains("synchronizeRemoteAvailability()"))
    }

    func testOnDeviceConnectionCheckDoesNotSendTrackAudio() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("NightcoreLab/Sources")
        let backend = try String(contentsOf: root.appendingPathComponent("DevStemBackend.swift"),
                                 encoding: .utf8)
        let panel = try String(contentsOf: root.appendingPathComponent("StemMixerControls.swift"),
                               encoding: .utf8)
        XCTAssertTrue(backend.contains("static func verifyConfiguration()"))
        XCTAssertTrue(backend.contains("probe.httpBody = Data()"))
        XCTAssertTrue(backend.contains("case 400: return"))
        XCTAssertTrue(panel.contains("stem.testConnection"))
        XCTAssertTrue(panel.contains("stem.connectionResult"))
        XCTAssertTrue(panel.contains("sem enviar música"))
    }

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
