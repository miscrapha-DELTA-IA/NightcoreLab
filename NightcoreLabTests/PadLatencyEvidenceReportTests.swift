import XCTest
@testable import NightcoreLab

final class PadLatencyEvidenceReportTests: XCTestCase {
    private func summary() -> PadLatencySummary {
        let warm = PadLatencySummary.Percentiles(p50: 1.5, p95: 6.0, max: 8.0)
        let cold = PadLatencySummary.Percentiles(p50: 42.0, p95: 42.0, max: 42.0)
        return PadLatencySummary(
            accepted: 41, failed: 2, warmCount: 40, coldCount: 1,
            touchDispatch: warm, touchToCommand: warm,
            warmCommand: warm, coldCommand: cold,
            coldEngineStart: cold, nodeStop: warm,
            nodeSchedule: warm, nodePlay: warm)
    }

    func testNoDataCannotBeMistakenForSuccessfulMeasurement() {
        let text = PadLatencyEvidenceReport.render([])
        XCTAssertTrue(text.contains("No completed sessions"))
        XCTAssertTrue(text.contains("NOT measure acoustic onset"))
    }

    func testReportContainsMetricsRouteTypeAndTrueEngineState() {
        let result = PadLatencyEvidenceReport.render([
            PadLatencyEvidenceSession(
                context: PadLatencyCaptureContext(
                    scenario: .warm, outputRouteType: "Speaker",
                    engineRunningAtStart: true,
                    musicPlayingAtStart: true, hapticsEnabled: false),
                summary: summary()),
            PadLatencyEvidenceSession(
                context: PadLatencyCaptureContext(
                    scenario: .cold, outputRouteType: "BluetoothA2DP",
                    engineRunningAtStart: true,
                    musicPlayingAtStart: false, hapticsEnabled: true),
                summary: summary())
        ])
        XCTAssertTrue(result.contains("SESSION 1: Engine quente"))
        XCTAssertTrue(result.contains("SESSION 2: Primeiro toque frio"))
        XCTAssertTrue(result.contains("Speaker"))
        XCTAssertTrue(result.contains("BluetoothA2DP"))
        XCTAssertTrue(result.contains("Accepted: 41, rejected: 2, warm: 40, cold: 1"))
        XCTAssertTrue(result.contains("Warm audio command"))
        XCTAssertTrue(result.contains("Touch event → audio command"))
        XCTAssertTrue(result.contains("node.stop"))
        XCTAssertTrue(result.contains("scheduleBuffer"))
        XCTAssertTrue(result.contains("node.play"))
        XCTAssertTrue(result.contains("engine was already running"))
        XCTAssertTrue(result.contains("not measured"))
    }

    func testColdCaptureWithStoppedEngineHasNoMisleadingWarning() {
        let result = PadLatencyEvidenceReport.render([
            PadLatencyEvidenceSession(
                context: .init(scenario: .cold,
                               outputRouteType: "Speaker",
                               engineRunningAtStart: false,
                               musicPlayingAtStart: false,
                               hapticsEnabled: false),
                summary: summary())
        ])
        XCTAssertFalse(result.contains("WARNING: engine was already running"))
        XCTAssertTrue(result.contains("Engine running at capture start: no"))
    }

    func testMissingSoftwareDataExplicitlyPrintedNA() {
        let empty = PadLatencySummary(
            accepted: 0, failed: 0, warmCount: 0, coldCount: 0,
            touchDispatch: nil, touchToCommand: nil,
            warmCommand: nil, coldCommand: nil, coldEngineStart: nil,
            nodeStop: nil, nodeSchedule: nil, nodePlay: nil)
        let text = PadLatencyEvidenceReport.render([
            PadLatencyEvidenceSession(context: .init(
                scenario: .withMusic, outputRouteType: "unknown",
                engineRunningAtStart: false,
                musicPlayingAtStart: false, hapticsEnabled: false),
                                      summary: empty)
        ])
        XCTAssertTrue(text.contains("Warm audio command: n/a"))
        XCTAssertTrue(text.contains("node.stop: n/a"))
        XCTAssertTrue(text.contains("No automatic A/B/C diagnosis"))
    }
}
