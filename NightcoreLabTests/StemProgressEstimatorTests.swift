import XCTest
#if canImport(NightcoreLab)
@testable import NightcoreLab
#else
@testable import GnarlyNeuralDSP
#endif

final class StemProgressEstimatorTests: XCTestCase {
    func testColdStartIsNotExtrapolatedToTheWholeSong() {
        var estimator = StemProgressEstimator()
        estimator.record(seconds: 300, recoveredMemory: false)
        XCTAssertNil(estimator.remainingSeconds(segments: 50))
        estimator.record(seconds: 10, recoveredMemory: false)
        XCTAssertNil(estimator.remainingSeconds(segments: 49))
        estimator.record(seconds: 12, recoveredMemory: false)
        XCTAssertEqual(estimator.remainingSeconds(segments: 48), 528)
    }

    func testMemoryRecoveryAndInvalidTimingsDoNotPolluteEstimate() {
        var estimator = StemProgressEstimator()
        estimator.record(seconds: 100, recoveredMemory: false)
        estimator.record(seconds: 10, recoveredMemory: false)
        estimator.record(seconds: 500, recoveredMemory: true)
        estimator.record(seconds: .nan, recoveredMemory: false)
        estimator.record(seconds: -1, recoveredMemory: false)
        XCTAssertNil(estimator.remainingSeconds(segments: 10))
        estimator.record(seconds: 10, recoveredMemory: false)
        XCTAssertEqual(estimator.remainingSeconds(segments: 10), 100)
    }

    func testRecentMedianAdaptsWithoutOneSlowSegmentDominating() {
        var estimator = StemProgressEstimator()
        estimator.record(seconds: 100, recoveredMemory: false)
        for seconds in [10.0, 11, 200, 10, 12] { estimator.record(seconds: seconds, recoveredMemory: false) }
        XCTAssertEqual(estimator.remainingSeconds(segments: 10), 110)
        for _ in 0..<5 { estimator.record(seconds: 20, recoveredMemory: false) }
        XCTAssertEqual(estimator.remainingSeconds(segments: 10), 200)
        XCTAssertNil(estimator.remainingSeconds(segments: 0))
    }
}
