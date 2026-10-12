import Foundation

/// Curated, versioned recipes. projectM's separation of presets and renderer,
/// adapted to the existing CreativePreset, VisualPreset and VisualResponse.
/// A catalogue selection does not silently change a user's AppTheme or
/// karaoke typography. Other visual targets remain descriptive until enabled.
enum CreativePresetCatalog {
    static let storageKey = "creativePresetID"
    static let defaultID = "original"

    static let all: [CreativeVisualProgram] = [
        CreativeVisualProgram(
            preset: CreativePreset(
                id: "original", name: "Original",
                theme: .acid, typographyStyle: .neon,
                visualStyle: VisualPreset(
                    background: .marble, intensity: 0.8, motion: 0.4),
                audioReaction: .responsive)),
        CreativeVisualProgram(
            preset: CreativePreset(
                id: "bass-pulse", name: "Bass Pulse",
                theme: .crimson, typographyStyle: .neon,
                visualStyle: VisualPreset(
                    background: .marble,
                    shaderParameters: .init(distortion: 0.75, glow: 0.85),
                    intensity: 0.95, motion: 0.6),
                audioReaction: .responsive),
            rules: [
                CreativeParameterRule(
                    target: .playerGlow,
                    equation: CreativeEquation(signal: .bass, gain: 1)),
                CreativeParameterRule(
                    target: .marbleDistortion,
                    equation: CreativeEquation(signal: .bass, gain: 0.7))
            ]),
        CreativeVisualProgram(
            preset: CreativePreset(
                id: "night-drive", name: "Night Drive",
                theme: .cyber, typographyStyle: .neon,
                visualStyle: VisualPreset(
                    background: .marble,
                    shaderParameters: .init(distortion: 0.4, glow: 0.8),
                    intensity: 0.65, motion: 0.35),
                audioReaction: .responsive),
            rules: [
                CreativeParameterRule(
                    target: .playerGlow,
                    equation: CreativeEquation(
                        signal: .energy, operation: .add, gain: 0.22)),
                CreativeParameterRule(
                    target: .lyricKinetics,
                    equation: CreativeEquation(
                        signal: .mid, operation: .multiply, gain: 0.6, bias: 0.4))
            ]),
        CreativeVisualProgram(
            preset: CreativePreset(
                id: "soft-flow", name: "Soft Flow",
                theme: .noir, typographyStyle: .magazineCutout,
                visualStyle: VisualPreset(
                    background: .marble,
                    shaderParameters: .init(distortion: 0.2, glow: 0.4),
                    intensity: 0.55, motion: 0.3),
                audioReaction: .responsive),
            rules: [
                CreativeParameterRule(
                    target: .playerGlow,
                    equation: CreativeEquation(
                        signal: .timeSine, operation: .multiply,
                        gain: 0.45, bias: 0.55, frequency: 0.3))
            ])
    ]

    static func program(for id: String) -> CreativeVisualProgram {
        all.first(where: { $0.id == id }) ?? all[0]
    }

    /// Preserve app-global theme/typography. The programme only describes
    /// reaction parameters and future visual targets; the current UI binds
    /// the player outline and the existing Marble distortion uniform.
    static func effectiveProgram(id: String, theme: AppTheme,
                                 typography: KaraokeTypographyStyle,
                                 background: PlayerBackgroundStyle,
                                 reaction: CreativePreset.AudioReaction) -> CreativeVisualProgram {
        let recipe = program(for: id)
        let configured = CreativePreset(
            id: recipe.id, name: recipe.preset.name,
            theme: theme, typographyStyle: typography,
            visualStyle: VisualPreset(
                background: .init(existing: background),
                shaderParameters: recipe.preset.visualStyle.shaderParameters,
                intensity: recipe.preset.visualStyle.intensity,
                motion: recipe.preset.visualStyle.motion),
            audioReaction: reaction)
        return CreativeVisualProgram(preset: configured, rules: recipe.rules)
    }
}
