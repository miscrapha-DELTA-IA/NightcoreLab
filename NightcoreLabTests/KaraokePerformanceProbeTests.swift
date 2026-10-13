import XCTest
@testable import NightcoreLab

final class KaraokePerformanceProbeTests: XCTestCase {
    func testDisabledProbeHasNoObservations() {
        let probe = KaraokePerformanceProbe(enabled: false)
        probe.timelineTick(expectedInterval: 1.0 / 60, at: 100)
        probe.typographyResolved(in: 0.5)
        probe.activeLineChanged(at: 100)
        probe.scrollRequested(animatedDuration: 0.4, automatic: true, at: 100.01)
        probe.preparedLineConstructed()
        XCTAssertEqual(probe.snapshot().timelineTicks, 0)
        XCTAssertEqual(probe.snapshot().typographyResolves, 0)
        XCTAssertEqual(probe.snapshot().scrollRequests, 0)
    }

    func testSyntheticFastLinesExposeOverlappingAnimationRisk() {
        let probe = KaraokePerformanceProbe(enabled: true)
        // A 400-ms scroll animation cannot finish before 180-ms lyric lines.
        probe.activeLineChanged(at: 100)
        probe.scrollRequested(animatedDuration: 0.4, automatic: true, at: 100.005)
        probe.activeLineChanged(at: 100.18)
        probe.scrollRequested(animatedDuration: 0.4, automatic: true, at: 100.185)
        probe.activeLineChanged(at: 100.36)
        probe.scrollRequested(animatedDuration: 0.4, automatic: true, at: 100.365)
        let result = probe.snapshot()
        XCTAssertEqual(result.activeLineChanges, 3)
        XCTAssertEqual(result.scrollRequests, 3)
        XCTAssertEqual(result.overlappingScrollRisks, 2)
        XCTAssertEqual(result.meanLineToScrollMS, 5, accuracy: 0.0001)
        XCTAssertEqual(result.requestedAnimationSeconds, 1.2, accuracy: 0.0001)
    }

    func testTimelineIntervalsAndTypographicResolutionAreAggregated() {
        let probe = KaraokePerformanceProbe(enabled: true)
        probe.timelineTick(expectedInterval: 1.0 / 60, at: 5)
        probe.timelineTick(expectedInterval: 1.0 / 60, at: 5.017)
        probe.timelineTick(expectedInterval: 1.0 / 60, at: 5.08)
        probe.typographyResolved(in: 0.001)
        probe.typographyResolved(in: 0.003)
        probe.preparedLineConstructed()
        let result = probe.snapshot()
        XCTAssertEqual(result.timelineTicks, 3)
        XCTAssertEqual(result.longFrameGaps, 1)
        XCTAssertEqual(result.maxFrameIntervalMS, 63, accuracy: 0.0001)
        XCTAssertEqual(result.meanTypographyResolveMS, 2, accuracy: 0.0001)
        XCTAssertEqual(result.preparedLineConstructions, 1)
        probe.reset()
        XCTAssertEqual(probe.snapshot().timelineTicks, 0)
        XCTAssertEqual(probe.snapshot().preparedLineConstructions, 0)
    }
}
