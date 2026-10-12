import Foundation

/// Declarative typography vocabulary. Only neon/magazineCutout are currently
/// rendered; remaining cases reserve stable identifiers for future versions.
enum TypographyStyle: String, Codable, CaseIterable, Sendable {
    case neon, magazineCutout, glitch, kinetic, minimal
}

enum TypographyAudioReaction: String, Codable, Sendable {
    case off, subtle, responsive

    var gain: Double {
        switch self {
        case .off: return 0
        case .subtle: return 0.35
        case .responsive: return 1
        }
    }
}

struct TypographyPreset: Codable, Equatable, Sendable {
    let style: TypographyStyle
    let audioReaction: TypographyAudioReaction
    /// 0 preserves Neon/Magazine legacy pixels; 1 reaches the bounded extra
    /// effect range. New styles get a nonzero default when selected explicitly.
    let effectIntensity: Double
    let audioMapping: TypographyAudioMapping
    let deterministicSeed: UInt64

    init(style: TypographyStyle,
         audioReaction: TypographyAudioReaction = .off,
         effectIntensity: Double? = nil,
         audioMapping: TypographyAudioMapping? = nil,
         deterministicSeed: UInt64 = 0) {
        self.style = style
        self.audioReaction = audioReaction
        let desired = effectIntensity ??
            ((style == .neon || style == .magazineCutout) ? 0 : 0.65)
        self.effectIntensity = desired.isFinite ? min(1, max(0, desired)) : 0
        self.audioMapping = audioMapping ??
            (style == .kinetic ? .kinetic : .legacy)
        self.deterministicSeed = deterministicSeed
    }

    /// Preserve both existing karaoke styles with NO reactive visual changes.
    init(legacy style: KaraokeTypographyStyle) {
        self.init(style: style == .neon ? .neon : .magazineCutout)
    }

    var legacyStyle: KaraokeTypographyStyle {
        style == .magazineCutout ? .magazineCutout : .neon
    }

    private enum CodingKeys: String, CodingKey {
        case style, audioReaction, effectIntensity, audioMapping, deterministicSeed
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let style = try c.decode(TypographyStyle.self, forKey: .style)
        let reaction = try c.decode(TypographyAudioReaction.self, forKey: .audioReaction)
        let intensity = try c.decodeIfPresent(Double.self, forKey: .effectIntensity)
        let mapping = try c.decodeIfPresent(TypographyAudioMapping.self, forKey: .audioMapping)
        let seed = try c.decodeIfPresent(UInt64.self, forKey: .deterministicSeed) ?? 0
        guard (intensity.map { $0.isFinite && (0...1).contains($0) } ?? true),
              (mapping?.isValid ?? true) else {
            throw DecodingError.dataCorrupted(.init(
                codingPath: decoder.codingPath,
                debugDescription: "Invalid typography preset intensity/mapping"))
        }
        self.init(style: style, audioReaction: reaction,
                  effectIntensity: intensity, audioMapping: mapping,
                  deterministicSeed: seed)
    }
}
