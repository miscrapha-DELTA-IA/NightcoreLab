import XCTest
@testable import NightcoreLab

@MainActor
final class PadPerformanceModeLifetimeTests: XCTestCase {
    func testOpenDeckKeepsExistingEngineWarmAndCloseRestoresIdleStop() async throws {
        let audio = AudioEngineManager(idleStopDelay: .milliseconds(20))
        audio.beginPerformanceMode()
        XCTAssertTrue(audio.isAudioEngineRunning)
        XCTAssertTrue(audio.triggerPad("kick"))
        try await Task.sleep(for: .milliseconds(180))
        XCTAssertTrue(audio.isAudioEngineRunning)
        XCTAssertTrue(audio.triggerPad("snare"))
        audio.endPerformanceMode()
        try await Task.sleep(for: .milliseconds(180))
        XCTAssertFalse(audio.isAudioEngineRunning)
    }

    func testModeMethodsAreIdempotentAndStandalonePadsRetainLegacyBehavior() async throws {
        let audio = AudioEngineManager(idleStopDelay: .milliseconds(20))
        audio.beginPerformanceMode()
        audio.beginPerformanceMode()
        XCTAssertTrue(audio.triggerPad("open-hat"))
        audio.endPerformanceMode()
        audio.endPerformanceMode()
        try await Task.sleep(for: .milliseconds(180))
        XCTAssertFalse(audio.isAudioEngineRunning)
        XCTAssertTrue(audio.triggerPad("kick"))
        XCTAssertTrue(audio.isAudioEngineRunning)
    }
}
