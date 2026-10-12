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

    init(style: TypographyStyle, audioReaction: TypographyAudioReaction = .off) {
        self.style = style
        self.audioReaction = audioReaction
    }

    /// Preserve both existing karaoke styles with NO reactive visual changes.
    init(legacy style: KaraokeTypographyStyle) {
        self.init(style: style == .neon ? .neon : .magazineCutout)
    }

    var legacyStyle: KaraokeTypographyStyle {
        style == .magazineCutout ? .magazineCutout : .neon
    }
}
