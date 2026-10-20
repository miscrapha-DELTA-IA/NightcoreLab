import XCTest
@testable import NightcoreLab

final class StemAudioMathTests: XCTestCase {
    func testMixtureConsistencyReconstructsStereoSource() throws {
        let count = 44_100
        let left = (0..<count).map { Float(sin(Double($0) * 0.027)) * 0.4 }
        let right = (0..<count).map { Float(cos(Double($0) * 0.031)) * 0.4 }
        var stems: [StemKind: StereoStemChunk] = [:]
        for stem in StemKind.allCases {
            stems[stem] = StereoStemChunk(
                left: left.map { $0 * 0.2 }, right: right.map { $0 * 0.2 })
        }
        try StemAudioMath.enforceMixture(left: left, right: right, stems: &stems)
        let leftSNR = StemAudioMath.reconstructionSNR(
            reference: left, stems: StemKind.allCases.map { stems[$0]!.left })
        let rightSNR = StemAudioMath.reconstructionSNR(
            reference: right, stems: StemKind.allCases.map { stems[$0]!.right })
        XCTAssertGreaterThan(leftSNR, 110, "left reconstruction SNR: \(leftSNR) dB")
        XCTAssertGreaterThan(rightSNR, 110, "right reconstruction SNR: \(rightSNR) dB")
    }

    func testCrossfadeWeightsPreserveConstantMixture() {
        for i in 0..<44_100 {
            XCTAssertEqual(StemAudioMath.crossfade(previous: 0.25, next: 0.25,
                                                   index: i, count: 44_100), 0.25,
                           accuracy: 1e-6)
        }
    }
}
