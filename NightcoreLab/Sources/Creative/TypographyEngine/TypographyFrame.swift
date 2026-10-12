import Foundation

/// The legacy magazine palette indices and rotation are resolved once outside
/// the view, without depending on UIKit/SwiftUI or Swift's randomized Hasher.
struct TypographyMagazineAppearance: Equatable, Sendable {
    let rotation: Double
    let fontIndex: Int
    let toneIndex: Int

    var legacy: MagazineWordAppearance {
        MagazineWordAppearance(
            rotation: rotation,
            font: MagazineCutoutFont(rawValue: fontIndex) ?? .system,
            tone: MagazineCutoutTone(rawValue: toneIndex) ?? .black)
    }
}

enum TypographyLineStatus: String, Codable, Sendable {
    case past, active, upcoming
}

struct LyricsState: Sendable {
    let line: TimedLyricLine
    let status: TypographyLineStatus
}

struct TypographyWordFrame: Equatable, Sendable, Identifiable {
    let word: WordSync
    let progress: Double
    let seed: UInt64
    let scale: Double
    let glowStrength: Double
    let magazine: TypographyMagazineAppearance?

    var id: Int { word.id }
}

struct TypographyFrame: Equatable, Sendable {
    let lineID: Int
    let lyricTime: TimeInterval
    let preset: TypographyPreset
    let status: TypographyLineStatus
    let activeWordID: Int?
    let words: [TypographyWordFrame]

    func word(id: Int) -> TypographyWordFrame? {
        words.first(where: { $0.id == id })
    }
}
