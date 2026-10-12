import Foundation

/// Chromatic spelling is deliberately separate from a screen color or mood.
enum MusicalPitchClass: String, Codable, CaseIterable, Sendable {
    case c, cSharp, d, dSharp, e, f, fSharp, g, gSharp, a, aSharp, b
}

enum MusicalScale: String, Codable, Sendable {
    case major, minor
}

/// Several plausible keys may coexist, e.g. C minor and E-flat major.
struct KeyHypothesis: Codable, Equatable, Sendable {
    let tonic: MusicalPitchClass
    let scale: MusicalScale
    let confidence: Double
}

struct KeyAnalysisResult: Codable, Equatable, Sendable {
    /// Sorted by descending confidence. Empty means no reliable key evidence.
    let hypotheses: [KeyHypothesis]
    let provenance: ExpressionProvenance

    var key: MusicalPitchClass? { hypotheses.first?.tonic }
    var scale: MusicalScale? { hypotheses.first?.scale }
    var confidence: Double { hypotheses.first?.confidence ?? 0 }

    func isValid(sourceDuration: TimeInterval) -> Bool {
        guard provenance.isValid(sourceDuration: sourceDuration),
              hypotheses.count <= 24 else { return false }
        var observed = Set<String>()
        var previousConfidence = Double.infinity
        for item in hypotheses {
            let identity = item.tonic.rawValue + "/" + item.scale.rawValue
            guard item.confidence.isFinite, (0...1).contains(item.confidence),
                  item.confidence <= previousConfidence,
                  observed.insert(identity).inserted else { return false }
            previousConfidence = item.confidence
        }
        return true
    }
}
