import XCTest
@testable import NightcoreLab

final class EnergyBudgetTests: XCTestCase {
    func testNormalAndLowPower() {
        let normal = EnergyBudget()
        XCTAssertEqual(normal.maxVisualFPS, 60)
        XCTAssertTrue(normal.allowsNewAnalysis)
        XCTAssertTrue(normal.allowsDecorativeMotion)
        XCTAssertTrue(normal.allowsExport)
        let low = EnergyBudget(lowPower: true)
        XCTAssertEqual(low.maxVisualFPS, 30)
        XCTAssertFalse(low.allowsNewAnalysis)
        XCTAssertTrue(low.allowsExport)
    }

    func testThermalAdmissionAndCadence() {
        for (state, fps, analysis, motion, export) in [
            (EnergyBudget.Thermal.nominal, 60.0, true, true, true),
            (.fair, 30, true, true, true),
            (.serious, 15, false, true, true),
            (.critical, 1, false, false, false)
        ] {
            let budget = EnergyBudget(thermal: state)
            XCTAssertEqual(budget.maxVisualFPS, fps)
            XCTAssertEqual(budget.allowsNewAnalysis, analysis)
            XCTAssertEqual(budget.allowsDecorativeMotion, motion)
            XCTAssertEqual(budget.allowsExport, export)
        }
    }

    func testBackgroundAndAccessibilityAreIndependent() {
        for state in [EnergyBudget.AppState.inactive, .background] {
            let budget = EnergyBudget(appState: state)
            XCTAssertFalse(budget.allowsNewAnalysis)
            XCTAssertFalse(budget.allowsDecorativeMotion)
            XCTAssertFalse(budget.allowsVisualUpdates)
            XCTAssertFalse(budget.allowsExport)
        }
        let reduced = EnergyBudget(reduceMotion: true)
        XCTAssertFalse(reduced.allowsDecorativeMotion)
        XCTAssertTrue(reduced.allowsVisualUpdates, "Karaoke progress remains useful")
        XCTAssertTrue(reduced.allowsExport)
    }

    func testAllCombinationsHaveFiniteBoundedIntervals() {
        for state in EnergyBudget.AppState.allCases {
            for thermal in EnergyBudget.Thermal.allCases {
                for low in [false, true] {
                    for reduced in [false, true] {
                        let budget = EnergyBudget(lowPower: low, thermal: thermal,
                                                  reduceMotion: reduced, appState: state)
                        XCTAssertTrue((1.0 / 60...1).contains(budget.visualInterval))
                    }
                }
            }
        }
    }

    func testDisallowedAnalysisDoesNotOpenSource() async throws {
        let engine = AudioFeatureEngine()
        let missing = URL(fileURLWithPath: "/missing/energy-budget-test.wav")
        try await engine.prepareAudio(at: missing, budget: EnergyBudget(thermal: .critical))
        let timeline = await engine.cachedTimeline(for: missing)
        XCTAssertNil(timeline)
    }
}
