import Foundation

enum StemAudioMath {
    /// Assign model reconstruction residual to `other` before any overlap.
    /// The four files then sum back to the source, including chunk seams.
    static func enforceMixture(left: [Float], right: [Float],
                               stems: inout [StemKind: StereoStemChunk]) throws {
        guard StemKind.allCases.allSatisfy({ stems[$0]?.left.count == left.count &&
                                             stems[$0]?.right.count == right.count }),
              left.count == right.count, var other = stems[.other] else {
            throw StemSeparationError.invalidModelOutput
        }
        for i in left.indices {
            let sumL = StemKind.allCases.reduce(Float(0)) { $0 + stems[$1]!.left[i] }
            let sumR = StemKind.allCases.reduce(Float(0)) { $0 + stems[$1]!.right[i] }
            other.left[i] += left[i] - sumL
            other.right[i] += right[i] - sumR
        }
        stems[.other] = other
    }

    /// At overlap index 0 only the preceding prediction contributes; at the
    /// end only the next prediction contributes. The two weights sum to one.
    static func crossfade(previous: Float, next: Float, index: Int, count: Int) -> Float {
        guard count > 1 else { return next }
        let nextWeight = Float(index) / Float(count - 1)
        return previous * (1 - nextWeight) + next * nextWeight
    }

    static func reconstructionSNR(reference: [Float], stems: [[Float]]) -> Double {
        guard !reference.isEmpty, stems.allSatisfy({ $0.count == reference.count }) else { return -.infinity }
        var signal = 0.0, noise = 0.0
        for i in reference.indices {
            let original = Double(reference[i])
            let reconstructed = stems.reduce(0.0) { $0 + Double($1[i]) }
            signal += original * original
            noise += pow(original - reconstructed, 2)
        }
        return noise == 0 ? .infinity : 10 * log10(signal / noise)
    }
}
