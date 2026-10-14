import XCTest
@testable import NightcoreLab

@MainActor
final class PadLatencyProbeTests: XCTestCase {
    private func hit(_ ms: Double, cold: Bool = false,
                     success: Bool = true) -> PadLatencySample {
        PadLatencySample(touchToHandlerMS: ms,
                         touchToCommandMS: ms + 3,
                         commandMS: ms + 2,
                         engineStartMS: cold ? 30 : 0,
                         nodeStopMS: 0.5,
                         nodeScheduleMS: 1.2,
                         nodePlayMS: 0.8,
                         wasCold: cold, succeeded: success)
    }

    func testOptInDoesNotCollectOutsideExplicitSession() {
        let probe = PadLatencyProbe()
        probe.record(hit(8))
        let result = probe.finish()
        XCTAssertEqual(result.accepted, 0)
        XCTAssertNil(result.touchDispatch)
        XCTAssertNil(result.warmCommand)
    }

    func testNearestRankPercentilesAndColdWarmIsolation() {
        let probe = PadLatencyProbe()
        probe.start()
        for delay in [1.0, 2.0, 3.0, 4.0, 80.0] {
            probe.record(hit(delay))
        }
        probe.record(hit(45, cold: true))
        probe.record(hit(0, success: false))
        let result = probe.finish()
        XCTAssertEqual(result.accepted, 6)
        XCTAssertEqual(result.failed, 1)
        XCTAssertEqual(result.warmCount, 5)
        XCTAssertEqual(result.coldCount, 1)
        XCTAssertEqual(result.warmCommand?.p50, 5)
        XCTAssertEqual(result.warmCommand?.p95, 82)
        XCTAssertEqual(result.touchDispatch?.p95, 80)
        XCTAssertEqual(result.coldEngineStart?.p50, 30)
        XCTAssertEqual(result.nodeStop?.max, 0.5)
        XCTAssertEqual(result.nodeSchedule?.p95, 1.2)
        XCTAssertEqual(result.nodePlay?.p50, 0.8)
    }

    func testBoundedCaptureAndExplicitReset() {
        let probe = PadLatencyProbe()
        probe.start()
        for _ in 0..<(PadLatencyProbe.maxSamples + 300) {
            probe.record(hit(3))
        }
        XCTAssertEqual(probe.finish().accepted, PadLatencyProbe.maxSamples)
        probe.start()
        probe.record(hit(11, cold: true))
        XCTAssertEqual(probe.finish().coldCount, 1)
        probe.start()
        probe.record(hit(5))
        probe.cancel()
        XCTAssertEqual(probe.finish().accepted, 0)
    }

    func testCommandBoundaryDoesNotIncludePostAudioBookkeeping() {
        let began = 10.0
        let nodePlayReturned = 10.002
        let idleBookkeepingFinished = 10.085

        let duration = PadLatencyProbe.elapsedMilliseconds(
            from: began, to: nodePlayReturned)
        XCTAssertEqual(duration, 2.0, accuracy: 0.000001)
        XCTAssertLessThan(duration, PadLatencyProbe.elapsedMilliseconds(
            from: began, to: idleBookkeepingFinished))

        XCTAssertTrue(PadLatencyProbe.elapsedMilliseconds(
            from: .nan, to: nodePlayReturned).isNaN)
        XCTAssertTrue(PadLatencyProbe.elapsedMilliseconds(
            from: nodePlayReturned, to: began).isNaN)
    }

    func testInvalidDurationsExcludedFromPercentiles() {
        let probe = PadLatencyProbe()
        probe.start()
        probe.record(PadLatencySample(
            touchToHandlerMS: -.infinity, touchToCommandMS: .nan,
            commandMS: .nan, engineStartMS: 0, nodeStopMS: 0,
            nodeScheduleMS: 0, nodePlayMS: 0,
            wasCold: false, succeeded: true))
        let result = probe.finish()
        XCTAssertNil(result.touchDispatch)
        XCTAssertNil(result.touchToCommand)
        XCTAssertNil(result.warmCommand)
        XCTAssertEqual(result.accepted, 1)
    }
}
