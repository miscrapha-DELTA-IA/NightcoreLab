import XCTest
@testable import NightcoreLab

@MainActor
final class PadPerformanceModeLifetimeTests: XCTestCase {
    /// The engine's idle stop is scheduled on the MainActor. Under a busy
    /// simulator, a fixed 180 ms sleep can resume before the stop task runs.
    /// Bound the wait without changing audio lifetimes or disabling the check.
    private func assertEventuallyStops(_ audio: AudioEngineManager) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(1.5))
        while audio.isAudioEngineRunning && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(25))
        }
        XCTAssertFalse(audio.isAudioEngineRunning,
                       "Audio engine must stop after the performance lease ends")
    }
    func testOpenDeckKeepsExistingEngineWarmAndCloseRestoresIdleStop() async throws {
        let audio = AudioEngineManager(idleStopDelay: .milliseconds(20))
        audio.beginPerformanceMode()
        XCTAssertTrue(audio.isAudioEngineRunning)
        XCTAssertTrue(audio.triggerPad("kick"))
        try await Task.sleep(for: .milliseconds(180))
        XCTAssertTrue(audio.isAudioEngineRunning)
        XCTAssertTrue(audio.triggerPad("snare"))
        audio.endPerformanceMode()
        try await assertEventuallyStops(audio)
    }

    func testModeMethodsAreIdempotentAndStandalonePadsRetainLegacyBehavior() async throws {
        let audio = AudioEngineManager(idleStopDelay: .milliseconds(20))
        audio.beginPerformanceMode()
        audio.beginPerformanceMode()
        XCTAssertTrue(audio.triggerPad("open-hat"))
        audio.endPerformanceMode()
        audio.endPerformanceMode()
        try await assertEventuallyStops(audio)
        XCTAssertTrue(audio.triggerPad("kick"))
        XCTAssertTrue(audio.isAudioEngineRunning)
    }
}
