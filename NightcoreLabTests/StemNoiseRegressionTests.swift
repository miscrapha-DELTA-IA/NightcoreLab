import Foundation
import XCTest
@testable import NightcoreLab

final class StemNoiseRegressionTests: XCTestCase {
    private let rate = 48_000.0

    private func signal(_ frequencies: [Double]) -> [Float] {
        (0..<96_000).map { sample in
            Float(frequencies.reduce(0) { sum, hz in
                sum + 0.2 * sin(2 * .pi * hz * Double(sample) / rate)
            })
        }
    }

    private func process(_ input: [Float], levels: [StemKind: Float],
                         blockSize: Int = 512) -> [Float] {
        let masker = InstantStemMasker(sampleRate: rate)
        for kind in StemKind.allCases { masker.set(kind, level: levels[kind] ?? 0) }
        var left = input, right = input.map { $0 * 0.7 }
        left.withUnsafeMutableBufferPointer { l in
            right.withUnsafeMutableBufferPointer { r in
                for offset in stride(from: 0, to: input.count, by: blockSize) {
                    masker.process(left: l.baseAddress! + offset, right: r.baseAddress! + offset,
                                   frames: min(blockSize, input.count - offset))
                }
            }
        }
        XCTAssertTrue(left.allSatisfy(\.isFinite))
        XCTAssertTrue(zip(left, right).allSatisfy { abs($0.0 * 0.7 - $0.1) < 0.000001 },
                      "Stem controls must preserve the original stereo relationship")
        return left
    }

    /// Project the settled output onto the input tones. Everything else is
    /// newly generated distortion, including harmonics and intermodulation.
    private func distortionDB(_ output: [Float], frequencies: [Double]) -> Double {
        let samples = output.dropFirst(48_000).map(Double.init)
        var fitted = [Double](repeating: 0, count: samples.count)
        for hz in frequencies {
            let phase = 2 * Double.pi * hz / rate
            let sine = samples.indices.map { sin(phase * Double($0)) }
            let cosine = samples.indices.map { cos(phase * Double($0)) }
            let a = 2 * zip(samples, sine).reduce(0) { $0 + $1.0 * $1.1 } / Double(samples.count)
            let b = 2 * zip(samples, cosine).reduce(0) { $0 + $1.0 * $1.1 } / Double(samples.count)
            for i in samples.indices { fitted[i] += a * sine[i] + b * cosine[i] }
        }
        let energy = samples.reduce(0) { $0 + $1 * $1 }
        let error = zip(samples, fitted).reduce(0) { $0 + pow($1.0 - $1.1, 2) }
        // A suppressed stem must also stay quiet in absolute terms.
        return 10 * log10(max(1e-20, error / max(energy, 1e-10)))
    }

    func testIsolatedSteadyTonesDoNotProduceBuzzOrHiss() {
        for hz in [60.0, 440, 1_000, 6_000] {
            let input = signal([hz])
            for kind in StemKind.allCases {
                let output = process(input, levels: [kind: 1])
                let distortion = distortionDB(output, frequencies: [hz])
                print("Stem noise: \(kind.rawValue) \(hz) Hz = \(distortion) dB")
                XCTAssertLessThan(distortion, -55, "\(kind.rawValue), \(hz) Hz")
            }
        }
    }

    func testBassAndVocalBandMixDoesNotGenerateIntermodulationNoise() {
        let input = signal([80, 1_000])
        for kind in StemKind.allCases {
            let output = process(input, levels: [kind: 1])
            XCTAssertLessThan(distortionDB(output, frequencies: [80, 1_000]), -55,
                              "\(kind.rawValue) must not modulate the mixture at audio rates")
        }
        let karaoke = process(input, levels: StemMixPreset.karaoke.levels)
        XCTAssertLessThan(distortionDB(karaoke, frequencies: [80, 1_000]), -55)
    }

    func testOutputDoesNotDependOnAudioCallbackBlockSize() {
        let input = signal([80, 1_000])
        let short = process(input, levels: [.bass: 1], blockSize: 127)
        let large = process(input, levels: [.bass: 1], blockSize: 8_193)
        XCTAssertEqual(short, large, "No truncated tail or boundary discontinuities")
        XCTAssertTrue(process([Float](repeating: 0, count: 8_193), levels: [.vocal: 1])
            .allSatisfy { $0 == 0 })
    }

    func testReturningToUnitySettlesBeforeTransparentBypass() {
        let masker = InstantStemMasker(sampleRate: rate)
        for kind in StemKind.allCases { masker.set(kind, level: 0) }
        var left = [Float](repeating: 0.2, count: 24_000), right = left
        func render() {
            let count = left.count
            left.withUnsafeMutableBufferPointer { l in
                right.withUnsafeMutableBufferPointer { r in
                    masker.process(left: l.baseAddress!, right: r.baseAddress!, frames: count)
                }
            }
        }
        render()
        for kind in StemKind.allCases { masker.set(kind, level: 1) }
        left = [Float](repeating: 0.2, count: 24_000); right = left
        render()
        XCTAssertLessThan(left[0], 0.001, "Restoring 100% must fade in rather than jump")
        XCTAssertLessThan(zip(left.dropFirst(), left).map { abs($0.0 - $0.1) }.max() ?? 1, 0.001)
        XCTAssertTrue(masker.isDirect)
        let original = signal([440])
        left = original; right = original
        render()
        XCTAssertEqual(left, original, "Restored neutral path must be bit-transparent")
    }
}
