import Foundation
import SwiftUI

/// Magazine Cutout per-word details. The effect selection itself is
/// `TypographyStyle`; these types only describe the cutout tiles.
enum MagazineCutoutFont: Int, CaseIterable {
    case system, serif, monospaced, display

    /// The descriptor is pure data so live lyrics and frozen Story frames pick
    /// the same font even when resolved on different threads.
    func family(for style: TypographyStyle) -> String {
        switch style {
        case .vinylSticker:
            return ["HelveticaNeue-CondensedBlack", "BodoniSvtyTwoITCTT-Bold",
                    "Futura-CondensedExtraBold", "HelveticaNeue-Black"] [rawValue]
        case .dymoTicket:
            return ["OldEnglishTextMT", "SnellRoundhand-Black",
                    "Copperplate-Bold", "AcademyEngravedLetPlain"] [rawValue]
        case .liquidCapsule:
            return ["Impact", "Courier-Bold", "Futura-CondensedExtraBold",
                    "AmericanTypewriter-Bold"] [rawValue]
        default:
            return ["Impact", "Didot-Bold", "Courier-Bold",
                    "Futura-CondensedExtraBold"] [rawValue]
        }
    }

    func font(size: CGFloat, style: TypographyStyle = .magazineCutout) -> Font {
        .custom(family(for: style), size: size,
                relativeTo: .title)
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
    var pack: TypographyStyle = .magazineCutout

    var fontDescriptor: String { font.family(for: pack) }
    var hasSolidCutoutBlock: Bool { pack.isMagazineClout }

    func displayText(_ text: String) -> String {
        if pack == .vinylSticker && font == .monospaced { return "\"\(text.uppercased())\"" }
        return pack == .vinylSticker || pack == .liquidCapsule
            ? text.uppercased() : text
    }

    func background(tone: MagazineCutoutTone, theme: KaraokeTheme) -> Color {
        guard tone != .accent else { return theme.fill }
        switch pack {
        case .vinylSticker where font == .system:
            return Color(red: 0.86, green: 0.04, blue: 0.13)
        case .dymoTicket where tone == .white:
            return Color(red: 0.78, green: 0.81, blue: 0.84)
        case .liquidCapsule where tone == .white:
            return Color(red: 0.98, green: 0.95, blue: 0.10)
        case .liquidCapsule where font == .serif:
            return Color(red: 0.91, green: 0.04, blue: 0.55)
        default:
            return tone.background(theme: theme)
        }
    }

    func ink(for tone: MagazineCutoutTone) -> Color {
        if pack == .vinylSticker && font == .system && tone != .accent { return .white }
        if pack == .liquidCapsule && font == .serif && tone != .accent { return .white }
        return tone.text
    }
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
