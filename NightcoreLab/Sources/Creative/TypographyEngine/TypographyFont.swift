import SwiftUI

/// Font-family axis of a TypographyPreset, independent of the effect style.
///
/// Formerly `StoryLyricTypography`. It was already shared by the live karaoke
/// and the Story through the same `story.lyricTypography` storage key; the
/// cases and raw values are unchanged, so persisted selections still decode.
///
/// Magazine Cutout keeps its own per-word fonts (`MagazineCutoutFont`), which
/// take precedence over this family, exactly as in the live karaoke.
enum TypographyFont: String, Codable, CaseIterable, Identifiable, Sendable {
    case classic, neon, mono, cinematic, typewriter

    static let storageKey = "story.lyricTypography"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .classic: return "Clássica"
        case .neon: return "Neon"
        case .mono: return "Mono"
        case .cinematic: return "Cinema"
        case .typewriter: return "Máquina"
        }
    }

    func font(size: CGFloat) -> Font {
        switch self {
        case .classic: return .system(size: size, weight: .heavy, design: .rounded)
        case .neon: return .system(size: size, weight: .black, design: .rounded)
        case .mono: return .system(size: size * 0.90, weight: .bold, design: .monospaced)
        case .cinematic: return .system(size: size * 1.06, weight: .bold, design: .serif)
        case .typewriter: return .system(size: size * 0.90, weight: .semibold, design: .monospaced)
        }
    }

    /// Story canvas size (540 pt wide).
    var font: Font { font(size: 35) }

    var tracking: CGFloat { self == .cinematic ? 0.6 : 0 }
}
