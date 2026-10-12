import Foundation

/// Relative pitch movement for eventual symbolic/audio-derived phrase analysis.
/// No melody or pitch extractor is implemented in Stage 3A.
enum MelodicMotion: String, Codable, Sendable {
    case ascending, descending, stable
}

struct MelodicPhrase: Codable, Equatable, Sendable {
    let startTime: TimeInterval
    let endTime: TimeInterval
    let contour: [MelodicMotion]
    let meanIntensity: Double?
    let confidence: Double
}

struct MelodicFeatures: Codable, Equatable, Sendable {
    let phrases: [MelodicPhrase]
    let provenance: ExpressionProvenance

    func isValid(sourceDuration: TimeInterval) -> Bool {
        guard provenance.isValid(sourceDuration: sourceDuration),
              phrases.count <= 8_192 else { return false }
        var previousEnd = 0.0
        for phrase in phrases {
            guard phrase.startTime.isFinite, phrase.endTime.isFinite,
                  phrase.startTime >= previousEnd,
                  phrase.endTime > phrase.startTime,
                  phrase.endTime <= provenance.analyzedThrough + 0.000_001,
                  phrase.contour.count <= 4_096,
                  phrase.confidence.isFinite,
                  (0...1).contains(phrase.confidence) else { return false }
            if let intensity = phrase.meanIntensity {
                guard intensity.isFinite, (0...1).contains(intensity) else { return false }
            }
            previousEnd = phrase.endTime
        }
        return true
    }
}
