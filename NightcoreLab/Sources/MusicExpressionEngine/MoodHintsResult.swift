import Foundation

/// Descriptive measurable features, NOT emotions or creative prescriptions.
enum MoodDimension: String, Codable, Sendable {
    case spectralBrightness, dynamicRange, rhythmicDensity
}

struct MoodHint: Codable, Equatable, Sendable {
    let dimension: MoodDimension
    let normalizedValue: Double
    let confidence: Double
    /// Example: "energy-rms-v1"; attribution, not a visual instruction.
    let evidence: String
}

struct MoodHintsResult: Codable, Equatable, Sendable {
    let hints: [MoodHint]
    let provenance: ExpressionProvenance

    func isValid(sourceDuration: TimeInterval) -> Bool {
        guard provenance.isValid(sourceDuration: sourceDuration),
              hints.count <= 32 else { return false }
        var seen = Set<String>()
        for hint in hints {
            guard hint.normalizedValue.isFinite,
                  (0...1).contains(hint.normalizedValue),
                  hint.confidence.isFinite,
                  (0...1).contains(hint.confidence),
                  !hint.evidence.isEmpty, hint.evidence.count <= 128,
                  seen.insert(hint.dimension.rawValue).inserted else { return false }
        }
        return true
    }
}
