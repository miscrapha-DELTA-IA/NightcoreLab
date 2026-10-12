import Foundation
import SwiftUI

/// Presentation-only policy inspired by lyric-reader ergonomics.
/// No relation to LRCLIB matching, word timing or the AVAudioEngine.
enum KaraokeFocusMode: String, Codable, CaseIterable, Identifiable {
    case spotlight
    case classic

    static let storageKey = "karaokeFocusMode"
    var id: String { rawValue }

    var title: String {
        switch self {
        case .spotlight: return "Foco"
        case .classic: return "Clássico"
        }
    }
}

/// Fixed per-line values: recompute only when the active line changes,
/// not from the active word's TimelineView.
struct KaraokeLineEmphasis: Equatable {
    let opacity: Double
    let scale: CGFloat
    let showsIndicator: Bool
}

enum KaraokeFocusResolver {
    static func emphasis(lineID: Int, activeID: Int?,
                         mode: KaraokeFocusMode) -> KaraokeLineEmphasis {
        guard mode == .spotlight, let activeID else {
            return KaraokeLineEmphasis(opacity: 1, scale: 1, showsIndicator: false)
        }
        let distance = abs(lineID - activeID)
        switch distance {
        case 0: return KaraokeLineEmphasis(opacity: 1, scale: 1, showsIndicator: true)
        case 1: return KaraokeLineEmphasis(opacity: 0.72, scale: 0.98, showsIndicator: false)
        case 2: return KaraokeLineEmphasis(opacity: 0.48, scale: 0.96, showsIndicator: false)
        default: return KaraokeLineEmphasis(opacity: 0.30, scale: 0.95, showsIndicator: false)
        }
    }

    static func scrollInset(for height: CGFloat) -> CGFloat {
        // Permit first and last lines to approach the middle of the viewport.
        max(95, min(340, height * 0.42))
    }
}
