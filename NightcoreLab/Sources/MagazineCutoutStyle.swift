import Foundation
import SwiftUI

/// Magazine Cutout per-word details. The effect selection itself is
/// `TypographyStyle`; these types only describe the cutout tiles.
enum MagazineCutoutFont: Int, CaseIterable {
    case system, serif, monospaced

    func font(size: CGFloat) -> Font {
        switch self {
        case .system: return .system(size: size, weight: .black, design: .rounded)
        case .serif: return .system(size: size * 1.02, weight: .heavy, design: .serif)
        case .monospaced: return .system(size: size * 0.92, weight: .bold, design: .monospaced)
        }
    }
}

enum MagazineCutoutTone: Int, CaseIterable {
    case black, white, accent

    func background(theme: KaraokeTheme) -> Color {
        switch self {
        case .black: return .black
        case .white: return .white
        case .accent: return theme.fill
        }
    }

    /// All 17 KaraokeTheme.fill colors are AA-contrast-safe against black.
    var text: Color { self == .black ? .white : .black }
}

struct MagazineWordAppearance: Equatable {
    let rotation: Double
    let font: MagazineCutoutFont
    let tone: MagazineCutoutTone
}

/// Pure resolver, evaluated only when a KaraokeLineView is constructed, not
/// within its TimelineView frame callback. No randomized values or animations.
enum KaraokeWordStyleResolver {
    /// FNV-1a is stable across processes, unlike Swift's randomized Hasher.
    private static func hash64(_ id: String) -> UInt64 {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in id.utf8 {
            hash = (hash ^ UInt64(byte)) &* 1_099_511_628_211
        }
        return hash
    }

    private static func normalized(_ hash: UInt64) -> Double {
        Double(hash & 0x00ff_ffff) / Double(0x00ff_ffff)
    }

    static func deterministicHash(_ id: String) -> Double {
        normalized(hash64(id))
    }

    static func resolve(lineID: Int, word: WordSync) -> MagazineWordAppearance {
        // Including text protects against a new word taking the old word index.
        let identity = "\(lineID):\(word.id):\(word.text)"
        let hash = hash64(identity)
        let rotation = -4 + 8 * normalized(hash)
        let font = MagazineCutoutFont(rawValue: Int((hash >> 24) % 3)) ?? .system
        let tone = MagazineCutoutTone(rawValue: Int((hash >> 32) % 3)) ?? .black
        return MagazineWordAppearance(rotation: rotation, font: font, tone: tone)
    }
}
