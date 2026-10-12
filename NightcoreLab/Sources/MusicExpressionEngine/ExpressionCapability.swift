import Foundation

/// Expression is opt-in and independent of energy, onsets and rhythm.
enum ExpressionCapability: String, Codable, CaseIterable, Hashable, Sendable {
    case key
    case sections
    case melody
    case moodHints
}

enum ExpressionCapabilityStatus: Codable, Equatable, Sendable {
    case notRequested
    case pending
    case available
    case failed(String)
}

/// Versions of a single algorithm and the upstream inputs it consumed.
/// A changed upstream rhythm/energy algorithm invalidates only expression
/// capabilities that explicitly declare it as a dependency.
struct ExpressionFingerprint: Codable, Equatable, Sendable {
    let algorithmVersion: Int
    let dependencyVersions: [String: Int]

    init(algorithmVersion: Int, dependencyVersions: [String: Int] = [:]) {
        self.algorithmVersion = algorithmVersion
        self.dependencyVersions = dependencyVersions
    }

    var isValid: Bool {
        algorithmVersion > 0 && dependencyVersions.allSatisfy {
            !$0.key.isEmpty && $0.value > 0
        }
    }
}

/// The measured audio prefix, method and provenance belong to each capability,
/// not to an aggregated source cache with a shared analyzer version.
struct ExpressionProvenance: Codable, Equatable, Sendable {
    let method: String
    let fingerprint: ExpressionFingerprint
    let analyzedThrough: TimeInterval
    let confidence: Double

    func isValid(sourceDuration: TimeInterval) -> Bool {
        !method.isEmpty && method.count <= 128 &&
        fingerprint.isValid &&
        sourceDuration.isFinite && sourceDuration >= 0 &&
        analyzedThrough.isFinite && analyzedThrough >= 0 &&
        analyzedThrough <= sourceDuration + 0.000_001 &&
        confidence.isFinite && (0...1).contains(confidence)
    }
}
