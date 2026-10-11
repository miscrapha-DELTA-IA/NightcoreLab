import XCTest
@testable import NightcoreLab

final class TurbulentBackgroundTests: XCTestCase {
    func testEveryThemeProvidesFourFluidLights() {
        for theme in AppTheme.allCases {
            XCTAssertEqual(TurbulentPalette.colors(for: theme).count, 4,
                           "Missing fluid blob colors for \(theme.displayName)")
        }
    }

    func testMotionIsDeterministic() {
        let first = TurbulentMotion.sample(at: 123.45, blob: 2)
        let again = TurbulentMotion.sample(at: 123.45, blob: 2)
        XCTAssertEqual(first, again)
    }

    func testMotionRemainsFiniteAndBoundedOverTime() {
        let timestamps: [TimeInterval] = [
            0, 1, 50, 1_000, 32_400, 100_000,
            Date().timeIntervalSinceReferenceDate
        ]
        for index in 0..<4 {
            for time in timestamps {
                let sample = TurbulentMotion.sample(at: time, blob: index)
                XCTAssertTrue(sample.horizontal.isFinite)
                XCTAssertTrue(sample.vertical.isFinite)
                XCTAssertTrue(sample.scale.isFinite)
                XCTAssertLessThanOrEqual(abs(sample.horizontal), 0.141)
                XCTAssertLessThanOrEqual(abs(sample.vertical), 0.111)
                XCTAssertGreaterThanOrEqual(sample.scale, 0.91)
                XCTAssertLessThanOrEqual(sample.scale, 1.09)
            }
        }
    }

    func testEachLightMovesIndependently() {
        let first = TurbulentMotion.sample(at: 42, blob: 0)
        let another = TurbulentMotion.sample(at: 42, blob: 1)
        let later = TurbulentMotion.sample(at: 86, blob: 0)
        XCTAssertNotEqual(first, another)
        XCTAssertNotEqual(first, later)
    }
}
