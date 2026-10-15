import SwiftUI
import UIKit

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
        let native: UIFont
        switch self {
        case .classic: native = .systemFont(ofSize: size, weight: .heavy)
        case .neon: native = .systemFont(ofSize: size, weight: .black)
        case .mono: native = .monospacedSystemFont(ofSize: size * 0.90, weight: .bold)
        case .cinematic: native = .systemFont(ofSize: size * 1.06, weight: .bold)
        case .typewriter: native = .monospacedSystemFont(ofSize: size * 0.90, weight: .semibold)
        }
        let design: UIFontDescriptor.SystemDesign? = switch self {
        case .classic, .neon: .rounded
        case .cinematic: .serif
        case .mono, .typewriter: nil
        }
        return Font(uiFont: Self.cascaded(native, design: design))
    }

    static func cascaded(_ font: UIFont,
                         design: UIFontDescriptor.SystemDesign? = nil) -> UIFont {
        let fallbacks = ["PingFangSC-Regular", "GeezaPro", "AppleColorEmoji"]
            .map { UIFontDescriptor(name: $0, size: font.pointSize) }
        let styled = design.flatMap { font.fontDescriptor.withDesign($0) } ?? font.fontDescriptor
        let descriptor = styled.addingAttributes([.cascadeList: fallbacks])
        return UIFont(descriptor: descriptor, size: font.pointSize)
    }

    /// Story canvas size (540 pt wide).
    var font: Font { font(size: 35) }

    var tracking: CGFloat { self == .cinematic ? 0.6 : 0 }
}
