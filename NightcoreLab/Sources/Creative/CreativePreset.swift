import Foundation

/// A portable visual recipe referring to the EXISTING AppTheme and karaoke style.
struct CreativePreset: Codable, Equatable, Sendable, Identifiable {
    enum AudioReaction: String, Codable, CaseIterable, Sendable {
        case off
        case subtle
        case responsive
    }

    let id: String
    let name: String
    let theme: AppTheme
    let typographyStyle: TypographyStyle
    let visualStyle: VisualPreset
    let audioReaction: AudioReaction

    init(id: String, name: String, theme: AppTheme,
         typographyStyle: TypographyStyle,
         visualStyle: VisualPreset,
         audioReaction: AudioReaction = .off) {
        self.id = id
        self.name = name
        self.theme = theme
        self.typographyStyle = typographyStyle
        self.visualStyle = visualStyle
        self.audioReaction = audioReaction
    }

    /// Default is descriptive, not an activated effect or editor selection.
    static func current(theme: AppTheme, typographyStyle: TypographyStyle,
                        playerBackground: PlayerBackgroundStyle) -> CreativePreset {
        CreativePreset(
            id: "current",
            name: "Visual atual",
            theme: theme,
            typographyStyle: typographyStyle,
            visualStyle: VisualPreset(background: .init(existing: playerBackground)),
            audioReaction: .off
        )
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, theme, typographyStyle, visualStyle, audioReaction
    }

    /// AppTheme is intentionally NOT extended or modified to conform to Codable.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let rawTheme = try c.decode(String.self, forKey: .theme)
        guard let theme = AppTheme(rawValue: rawTheme) else {
            throw DecodingError.dataCorruptedError(
                forKey: .theme, in: c,
                debugDescription: "Unknown AppTheme: \(rawTheme)"
            )
        }
        self.init(id: try c.decode(String.self, forKey: .id),
                  name: try c.decode(String.self, forKey: .name),
                  theme: theme,
                  typographyStyle: try c.decode(TypographyStyle.self, forKey: .typographyStyle),
                  visualStyle: try c.decode(VisualPreset.self, forKey: .visualStyle),
                  audioReaction: try c.decode(AudioReaction.self, forKey: .audioReaction))
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(theme.rawValue, forKey: .theme)
        try c.encode(typographyStyle, forKey: .typographyStyle)
        try c.encode(visualStyle, forKey: .visualStyle)
        try c.encode(audioReaction, forKey: .audioReaction)
    }
}
