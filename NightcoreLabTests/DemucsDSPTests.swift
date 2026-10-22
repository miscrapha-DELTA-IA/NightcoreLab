import XCTest
#if canImport(NightcoreLab)
@testable import NightcoreLab
#else
@testable import GnarlyNeuralDSP
#endif

/// Parity of the Swift DSP with the Python reference (`convert/stemcommon.py`).
/// Golden values were produced by PyTorch — see docs/spike-report.ru.md.
final class DemucsDSPTests: XCTestCase {

    /// Golden signal: 0.05 + sin440 + 0.5·sin1000, channels scaled ×1 and ×0.5.
    private func goldenSignal(scale: Float) -> [Float] {
        (0..<StemDSP.segmentSamples).map { i in
            let t = Double(i) / 44100.0
            return Float(0.05 + sin(2 * .pi * 440 * t) + 0.5 * sin(2 * .pi * 1000 * t)) * scale
        }
    }

    func testSTFTMatchesTorchGolden() {
        // (channel, bin, frame, re, im) taken from stemcommon.spec
        let golden: [(Int, Int, Int, Float, Float)] = [
            (0, 0, 100, 1.600060e+00, 0.000000e+00),
            (0, 41, 100, 1.540684e+01, 3.585856e+00),
            (0, 93, 100, 4.875119e+00, -6.249059e+00),
            (0, 41, 5, -1.479005e+01, 5.610980e+00),
            (1, 41, 200, -1.754493e+00, -7.712263e+00),
            (1, 93, 300, 2.255642e+00, -3.258302e+00),
        ]
        let spectra = [StemDSP.stft(goldenSignal(scale: 1)), StemDSP.stft(goldenSignal(scale: 0.5))]
        for (c, b, f, re, im) in golden {
            let idx = b * StemDSP.frames + f
            XCTAssertEqual(spectra[c].re[idx], re, accuracy: max(2e-3, abs(re) * 1e-3),
                           "re @ c\(c) b\(b) f\(f)")
            XCTAssertEqual(spectra[c].im[idx], im, accuracy: max(2e-3, abs(im) * 1e-3),
                           "im @ c\(c) b\(b) f\(f)")
        }
    }

    func testRoundtripInteriorIsExact() {
        let x = goldenSignal(scale: 1)
        let (re, im) = StemDSP.stft(x)
        let y = StemDSP.istft(re: re, im: im)
        XCTAssertEqual(y.count, x.count)
        // The outer 4096 samples are lost by convention (same as PyTorch); in the chunked
        // pipeline the overlap covers them. The interior is exact.
        var maxErr: Float = 0
        for i in 4096..<(x.count - 4096) {
            maxErr = max(maxErr, abs(y[i] - x[i]))
        }
        XCTAssertLessThan(maxErr, 1e-4)
    }

    func testPadReflectMatchesTorchConvention() {
        // Reflect without repeating the edge sample: out[pad-1] == x[1]
        var x = [Float](repeating: 0, count: StemDSP.segmentSamples)
        for i in 0..<x.count { x[i] = Float(i % 977) }
        let p = StemDSP.padReflect(x)
        XCTAssertEqual(p.count, StemDSP.paddedLength)
        XCTAssertEqual(p[StemDSP.padLeft], x[0])
        XCTAssertEqual(p[StemDSP.padLeft - 1], x[1])
        XCTAssertEqual(p[StemDSP.padLeft - 2], x[2])
        XCTAssertEqual(p[StemDSP.padLeft + x.count - 1], x.last!)
        XCTAssertEqual(p[StemDSP.padLeft + x.count], x[x.count - 2])
    }

    func testTriangleWeightsShape() {
        let w = OverlapAdd.triangleWeights(StemDSP.segmentSamples)
        XCTAssertEqual(w.count, StemDSP.segmentSamples)
        XCTAssertEqual(w.max(), 1)
        XCTAssertGreaterThan(w[1], w[0])
        XCTAssertGreaterThan(w[w.count - 2], w[w.count - 1])
        // even length is symmetric
        XCTAssertEqual(w[0], w[w.count - 1], accuracy: 1e-6)
    }

    func testVectorOverlapKeepsAllSourcesAndExistingContext() {
        let length = 64, lanes = 8
        let window = OverlapAdd.triangleWeights(length)
        let separated = (0..<(length * lanes)).map { Float(sin(Double($0) * 0.17)) }
        var accumulated = (0..<(length * lanes)).map { Float($0 % 19) * 0.02 - 0.1 }
        var weights = window.reversed().map { $0 * 0.4 }
        var reference = accumulated, referenceWeights = weights
        for frame in 0..<length {
            referenceWeights[frame] += window[frame]
            for lane in 0..<lanes {
                reference[lane * length + frame] += separated[lane * length + frame] * window[frame]
            }
        }
        OverlapAdd.accumulate(separated, weight: window, accumulator: &accumulated, weights: &weights)
        for i in accumulated.indices { XCTAssertEqual(accumulated[i], reference[i], accuracy: 0.000001) }
        XCTAssertEqual(weights, referenceWeights)

        // A tail segment emits only its valid prefix, without touching output
        // outside that range or mixing source/channel lanes together.
        let count = 23
        for lane in 0..<lanes {
            var output = [Float](repeating: -999, count: length)
            accumulated.withUnsafeBufferPointer { input in
                weights.withUnsafeBufferPointer { total in
                    output.withUnsafeMutableBufferPointer { target in
                        OverlapAdd.restoreLane(input.baseAddress! + lane * length, weights: total.baseAddress!,
                            count: count, standardDeviation: 0.21, mean: 0.43, to: target.baseAddress!)
                    }
                }
            }
            for i in 0..<count {
                let expected = reference[lane * length + i] / referenceWeights[i] * 0.21 + 0.43 / 4
                XCTAssertEqual(output[i], expected, accuracy: 0.000001)
            }
            XCTAssertTrue(output[count...].allSatisfy { $0 == -999 })
        }
    }

    func testStridedFFTLayoutKeepsDCSeparateFromDroppedNyquist() {
        let spectrum = StemDSP.stft([Float](repeating: 0.5, count: StemDSP.segmentSamples))
        for frame in 0..<StemDSP.frames {
            XCTAssertEqual(spectrum.re[frame], 16, accuracy: 0.0001)
            XCTAssertEqual(spectrum.im[frame], 0)
            XCTAssertEqual(spectrum.re[1 * StemDSP.frames + frame], -8, accuracy: 0.0001)
            XCTAssertEqual(spectrum.re[200 * StemDSP.frames + frame], 0, accuracy: 0.0001)
        }
    }

    func testInPlaceWeightAdvanceExactlyMatchesOriginalRemoveAppend() {
        let original = (0..<256).map { i in
            i == 0 ? -Float.zero : Float(i) * 0.001 - 0.1
        }
        for amount in [0, 1, 3, 64, 192, 256] {
            var reference = original
            reference.removeFirst(amount)
            reference.append(contentsOf: repeatElement(Float.zero, count: amount))
            var optimized = original
            OverlapAdd.advanceWeights(&optimized, by: amount)
            XCTAssertEqual(optimized.count, original.count)
            XCTAssertEqual(optimized.map(\\.bitPattern), reference.map(\\.bitPattern),
                           "No normalization or overlap sample may change")
        }

        // Consecutive shifts also preserve an exact constant-size window.
        var reference = original, optimized = original
        for amount in [31, 8, 17, 1, 12, 64] {
            reference.removeFirst(amount)
            reference.append(contentsOf: repeatElement(Float.zero, count: amount))
            OverlapAdd.advanceWeights(&optimized, by: amount)
        }
        XCTAssertEqual(optimized.map(\\.bitPattern), reference.map(\\.bitPattern))
    }

    func testChunkOffsetsCoverTrack() {
        let total = StemDSP.segmentSamples * 3 + 1000
        let offs = OverlapAdd.offsets(totalSamples: total)
        XCTAssertEqual(offs.first, 0)
        XCTAssertLessThan(offs.last!, total)
        // consecutive chunks overlap by 25 % of a segment
        XCTAssertEqual(offs[1] - offs[0], Int(Double(StemDSP.segmentSamples) * 0.75))
        // the last chunk reaches the end of the track
        XCTAssertGreaterThanOrEqual(offs.last! + StemDSP.segmentSamples, total)
    }
}
