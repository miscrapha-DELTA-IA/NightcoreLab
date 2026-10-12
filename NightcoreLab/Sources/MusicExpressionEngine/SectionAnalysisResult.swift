import Foundation

/// Unknown and instrumental are valid outcomes; no chorus label is fabricated
/// from a change in energy alone.
enum MusicSectionLabel: String, Codable, Sendable {
    case unknown, intro, verse, chorus, bridge, buildup, instrumental, outro
}

struct MusicSection: Codable, Equatable, Sendable {
    let startTime: TimeInterval
    let endTime: TimeInterval
    let label: MusicSectionLabel
    let confidence: Double
}

struct SectionAnalysisResult: Codable, Equatable, Sendable {
    /// Source-time intervals; gaps are allowed, overlaps are not.
    let sections: [MusicSection]
    let provenance: ExpressionProvenance

    func isValid(sourceDuration: TimeInterval) -> Bool {
        guard provenance.isValid(sourceDuration: sourceDuration),
              sections.count <= 8_192 else { return false }
        var previousEnd = 0.0
        for section in sections {
            guard section.startTime.isFinite, section.endTime.isFinite,
                  section.startTime >= previousEnd,
                  section.endTime > section.startTime,
                  section.endTime <= provenance.analyzedThrough + 0.000_001,
                  section.confidence.isFinite,
                  (0...1).contains(section.confidence) else { return false }
            previousEnd = section.endTime
        }
        return true
    }
}
