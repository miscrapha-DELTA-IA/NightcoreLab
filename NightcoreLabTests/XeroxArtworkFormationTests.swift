import Foundation
import XCTest
@testable import NightcoreLab

final class XeroxArtworkFormationTests: XCTestCase {
    func testRevealStartsHiddenAndCompletesWithinFirstFifth() {
        XCTAssertEqual(XeroxArtworkReveal.progress(at: 0, duration: 100), 0)
        XCTAssertEqual(XeroxArtworkReveal.progress(at: 10, duration: 100),
                       0.5, accuracy: 0.0000001)
        XCTAssertEqual(XeroxArtworkReveal.progress(at: 20, duration: 100), 1)
        XCTAssertEqual(XeroxArtworkReveal.progress(at: 35, duration: 100), 1)
        XCTAssertEqual(XeroxArtworkReveal.progress(at: .nan, duration: 100), 0)
        XCTAssertEqual(XeroxArtworkReveal.progress(at: -15, duration: 100), 0)
    }

    func testUnknownDurationUsesBoundedDeterministicFallback() {
        let baseline = XeroxArtworkReveal.progress(at: 12, duration: 0)
        XCTAssertEqual(baseline, 0.5, accuracy: 0.0000001)
        XCTAssertEqual(XeroxArtworkReveal.progress(at: 24, duration: .nan), 1)
    }

    func testEveryHalftoneCellFillsMonotonicallyWithoutRandomSeed() {
        for row in 0..<20 {
            for col in 0..<20 {
                let threshold = XeroxArtworkReveal.threshold(column: col, row: row)
                XCTAssertTrue((0...0.87).contains(threshold))
                XCTAssertEqual(XeroxArtworkReveal.cellFill(
                    progress: 0, column: col, row: row), 0)
                XCTAssertEqual(XeroxArtworkReveal.cellFill(
                    progress: 1, column: col, row: row), 1)
                let early = XeroxArtworkReveal.cellFill(
                    progress: 0.2, column: col, row: row)
                let middle = XeroxArtworkReveal.cellFill(
                    progress: 0.55, column: col, row: row)
                XCTAssertLessThanOrEqual(early, middle)
                XCTAssertEqual(threshold, XeroxArtworkReveal.threshold(
                    column: col, row: row))
            }
        }
    }
}
