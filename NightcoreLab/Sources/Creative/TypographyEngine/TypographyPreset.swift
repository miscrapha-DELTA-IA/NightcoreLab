import Foundation

/// The single effect vocabulary for lyrics, shared by the live karaoke, the
/// Story preview and the MP4 export. Replaces `KaraokeTypographyStyle`, whose
/// two raw values ("neon", "magazineCutout") are identical, so persisted
/// selections and encoded CreativePreset payloads keep decoding.
enum TypographyStyle: String, Codable, CaseIterable, Identifiable, Sendable {
    case neon, magazineCutout, glitch, kinetic, minimal
    case vinylSticker, dymoTicket, liquidCapsule

    /// Existing preference key; unchanged so the user's choice survives.
    static let storageKey = "karaokeTypography"

    static let storyObjectModels: [TypographyStyle] = [
        .magazineCutout, .vinylSticker, .dymoTicket, .liquidCapsule
    ]

    var shortObjectTitle: String {
        switch self {
        case .magazineCutout: return "Recorte"
        case .vinylSticker: return "Adesivo"
        case .dymoTicket: return "Fita"
        case .liquidCapsule: return "Cristal ⚡"
        default: return title
        }
    }

    var id: String { rawValue }

    var title: String {
        switch self {
        case .neon: return "Neon"
        case .magazineCutout: return "Magazine Cutout (Recorte Clássico)"
        case .glitch: return "Glitch"
        case .kinetic: return "Kinetic"
        case .minimal: return "Minimal"
        case .vinylSticker: return "Vinyl Sticker (Adesivo Street)"
        case .dymoTicket: return "Dymo Ticket (Fita / Ingresso Brutalista)"
        case .liquidCapsule: return "Liquid Capsule (Cristal ⚡)"
        }
    }

    /// The two styles that existed before Stage 10B. Packages authored before
    /// it recorded every other style as `.neon` in their CreativePreset.
    var predatesExtendedStyles: Bool {
        self == .neon || self == .magazineCutout
    }

    var isObjectModel: Bool {
        self == .vinylSticker || self == .dymoTicket || self == .liquidCapsule
    }
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
    /// Font family. Magazine Cutout overrides it per word.
    let font: TypographyFont

    init(style: TypographyStyle,
         audioReaction: TypographyAudioReaction = .off,
         effectIntensity: Double? = nil,
         audioMapping: TypographyAudioMapping? = nil,
         deterministicSeed: UInt64 = 0,
         font: TypographyFont = .classic) {
        self.style = style
        self.audioReaction = audioReaction
        let desired = effectIntensity ??
            ((style == .neon || style == .magazineCutout) ? 0 : 0.65)
        self.effectIntensity = desired.isFinite ? min(1, max(0, desired)) : 0
        self.audioMapping = audioMapping ??
            (style == .kinetic ? .kinetic : .legacy)
        self.deterministicSeed = deterministicSeed
        self.font = font
    }

    /// The ONE preset used by the live karaoke and frozen into a Story.
    /// Audio reaction stays off: the live karaoke resolves typography with
    /// `features: nil`, so any reaction would only exist in the MP4.
    static func current(style: TypographyStyle,
                        font: TypographyFont) -> TypographyPreset {
        TypographyPreset(style: style, audioReaction: .off, font: font)
    }

    private enum CodingKeys: String, CodingKey {
        case style, audioReaction, effectIntensity, audioMapping, deterministicSeed, font
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let style = try c.decode(TypographyStyle.self, forKey: .style)
        let reaction = try c.decode(TypographyAudioReaction.self, forKey: .audioReaction)
        let intensity = try c.decodeIfPresent(Double.self, forKey: .effectIntensity)
        let mapping = try c.decodeIfPresent(TypographyAudioMapping.self, forKey: .audioMapping)
        let seed = try c.decodeIfPresent(UInt64.self, forKey: .deterministicSeed) ?? 0
        // Presets saved before Stage 10B have no font: keep the app default.
        let font = try c.decodeIfPresent(TypographyFont.self, forKey: .font) ?? .classic
        guard (intensity.map { $0.isFinite && (0...1).contains($0) } ?? true),
              (mapping?.isValid ?? true) else {
            throw DecodingError.dataCorrupted(.init(
                codingPath: decoder.codingPath,
                debugDescription: "Invalid typography preset intensity/mapping"))
        }
        self.init(style: style, audioReaction: reaction,
                  effectIntensity: intensity, audioMapping: mapping,
                  deterministicSeed: seed, font: font)
    }
}
