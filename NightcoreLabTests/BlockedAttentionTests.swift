import XCTest
#if canImport(NightcoreLab)
@testable import NightcoreLab
#else
@testable import GnarlyNeuralDSP
#endif

final class BlockedAttentionTests: XCTestCase {
    func testGlobalAttentionMatchesIndependentDoubleReferenceAcrossTileBoundary() throws {
        let heads = 2, queries = 131, keys = 137, width = 8
        let q = (0..<(heads * queries * width)).map { Float(sin(Double($0) * 0.31)) }
        let k = (0..<(heads * keys * width)).map { Float(cos(Double($0) * 0.17)) }
        let v = (0..<(heads * keys * width)).map { Float(sin(Double($0) * 0.23)) }
        let output = try BlockedAttention.evaluate(query: q, key: k, value: v,
                                                  heads: heads, queries: queries, keys: keys, width: width)
        for head in 0..<heads {
            for query in [0, 63, 64, 127, 128, 130] {
                var scores = [Double](repeating: 0, count: keys)
                for key in 0..<keys {
                    scores[key] = (0..<width).reduce(0) { sum, d in
                        sum + Double(q[(head * queries + query) * width + d]) * Double(k[(head * keys + key) * width + d])
                    } / sqrt(Double(width))
                }
                let maximum = scores.max()!
                let probabilities = scores.map { exp($0 - maximum) }
                let total = probabilities.reduce(0, +)
                for d in 0..<width {
                    let expected = (0..<keys).reduce(0) { $0 + probabilities[$1] * Double(v[(head * keys + $1) * width + d]) } / total
                    XCTAssertEqual(Double(output[(head * queries + query) * width + d]), expected, accuracy: 0.000002)
                }
            }
        }
    }

    func testFarAwayKeysContributeAndCancellationInterruptsBetweenTiles() throws {
        let count = 130
        var values = [Float](repeating: 0, count: count)
        values[count - 1] = Float(count)
        let output = try BlockedAttention.evaluate(query: Array(repeating: 0, count: count),
            key: Array(repeating: 0, count: count), value: values,
            heads: 1, queries: count, keys: count, width: 1)
        XCTAssertTrue(output.allSatisfy { abs($0 - 1) < 0.000001 }, "Every query must attend to the farthest key, not just its tile")
        var calls = 0
        XCTAssertThrowsError(try BlockedAttention.evaluate(query: Array(repeating: 0, count: count),
            key: Array(repeating: 0, count: count), value: values,
            heads: 1, queries: count, keys: count, width: 1, check: {
                calls += 1
                if calls == 2 { throw CancellationError() }
            })) { XCTAssertTrue($0 is CancellationError) }
        XCTAssertEqual(calls, 2)
    }
}
