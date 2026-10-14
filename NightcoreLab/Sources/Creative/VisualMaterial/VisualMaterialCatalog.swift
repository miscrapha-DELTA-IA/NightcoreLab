import Foundation

/// Authored material data (look + its single audio mapping). The first two
/// after Original use the liquidMarble shader; the Stage 13B entries select
/// the procedural material shader by type. Selection goes through
/// CreativeExperienceResolver.material, never through this list directly.
enum VisualMaterialCatalog {
    static let originalMarble = VisualMaterial.legacyMarble
    static let cyberChrome = VisualMaterial(
        id: "cyber-chrome", name: "Cyber Chrome",
        parameters: .init(beatPulse: 0.6, pulseDecay: 9, offbeatScale: 0.5,
                          warpAmount: 0.12, brightnessBoost: 0.12),
        audioMapping: .init(bassToDistortion: 0.16, energyToBrightness: 0.06,
                            downbeatToAccent: 0.08))
    static let neonPulse = VisualMaterial(
        id: "neon-pulse", name: "Neon Pulse",
        parameters: .init(beatPulse: 0.85, pulseDecay: 8, offbeatScale: 0.55,
                          warpAmount: 0.24, brightnessBoost: 0.12,
                          stripingFrequency: 56, stripingMix: 0.78),
        audioMapping: .init(bassToDistortion: 0.20, energyToBrightness: 0.10,
                            downbeatToAccent: 0.06))
    static let glassSurface = VisualMaterial(
        id: "liquid-glass", name: "Liquid Glass", type: .liquidGlass,
        parameters: .init(beatPulse: 0.4, pulseDecay: 5),
        audioMapping: .init(energyToBrightness: 0.06, beatToPulse: 0.7))
    static let chromeNight = VisualMaterial(
        id: "chrome-night", name: "Chrome Night", type: .chrome,
        parameters: .init(beatPulse: 0.35, pulseDecay: 8),
        audioMapping: .init(energyToBrightness: 0.09))
    static let organicPulse = VisualMaterial(
        id: "organic-pulse", name: "Organic Pulse", type: .organicNoise,
        parameters: .init(beatPulse: 0.6, pulseDecay: 6),
        // Movement follows energy like the Bass Pulse program's motion (0.6).
        audioMapping: .init(bassToDistortion: 0.1, energyToMovement: 0.6))
    static let smoke = VisualMaterial(
        id: "atmospheric-smoke", name: "Atmospheric Smoke", type: .atmosphericSmoke,
        parameters: .init(beatPulse: 0.2, pulseDecay: 5),
        // Movement follows energy like the Soft Flow program's motion (0.3).
        audioMapping: .init(energyToBrightness: 0.06, energyToMovement: 0.3))
    static let advancedMarble = VisualMaterial(
        id: "advanced-marble", name: "Advanced Marble", type: .advancedMarble,
        parameters: .init(beatPulse: 0.6, pulseDecay: 6),
        audioMapping: .init(bassToDistortion: 0.10))
    /// Seven authored 5-stop palettes. Hex strings preserve exact art-direction
    /// values and avoid storing heavyweight images or SwiftUI Color in Codable.
    /// For four/three-color briefs the spare slots repeat an authored color.
    struct Palette: Equatable, Sendable {
        let hex: [String]
        init(_ stops: String...) { self.hex = stops }
    }
    static let curatedPalettes: [String: Palette] = [
        "neon-pulse": Palette("#040406", "#FF0088", "#00FF9D", "#00E5FF", "#F8FAFC"),
        "agate-zebra": Palette("#FFFFFF", "#050507", "#6C7A9C", "#F28C28", "#FFFFFF"),
        "void-gloss": Palette("#000000", "#00D2E6", "#00E5A3", "#F4DCE0", "#FF1A1A"),
        "terrazzo-magma": Palette("#0B0D11", "#E87A1E", "#D91414", "#D8DEC8", "#081E4A"),
        "airbrush-mirage": Palette("#121214", "#FF3B30", "#8E7CFF", "#FFB340", "#EBF2D5"),
        "groove-ebru": Palette("#008B94", "#F5A623", "#EE4035", "#F8B195", "#26292C"),
        "cymatic-rorschach": Palette("#050714", "#6699CC", "#F5F9FF", "#6699CC", "#050714")
    ]

    static let agateZebra = VisualMaterial(
        id: "agate-zebra", name: "Agate Zebra",
        parameters: .init(beatPulse: 0.36, stripingFrequency: 38,
                          stripingMix: 0.76, speckleIntensity: 0.12,
                          embossStrength: 0.38),
        audioMapping: .init(energyToBrightness: 0.035, beatToPulse: 0.45))
    static let voidGloss = VisualMaterial(
        id: "void-gloss", name: "Void Gloss",
        parameters: .init(beatPulse: 0.42, stripingFrequency: 22,
                          stripingMix: 0.28, voidThreshold: 0.64),
        audioMapping: .init(energyToBrightness: 0.04, beatToPulse: 0.45))
    static let terrazzoMagma = VisualMaterial(
        id: "terrazzo-magma", name: "Terrazzo Magma",
        parameters: .init(beatPulse: 0.4, stripingFrequency: 10,
                          stripingMix: 0.18, speckleIntensity: 0.78,
                          embossStrength: 0.58),
        audioMapping: .init(energyToBrightness: 0.04, beatToPulse: 0.45))
    static let airbrushMirage = VisualMaterial(
        id: "airbrush-mirage", name: "Airbrush Mirage",
        parameters: .init(beatPulse: 0.28, embossStrength: 0.12,
                          scanlineDensity: 96, diffusionSoftness: 0.84),
        audioMapping: .init(energyToBrightness: 0.035, beatToPulse: 0.45))
    static let grooveEbru = VisualMaterial(
        id: "groove-ebru", name: "Groove Ebru",
        parameters: .init(beatPulse: 0.35, stripingFrequency: 38,
                          stripingMix: 0.35, combStretch: 5.2),
        audioMapping: .init(energyToBrightness: 0.04, beatToPulse: 0.45))
    static let cymaticRorschach = VisualMaterial(
        id: "cymatic-rorschach", name: "Cymatic Rorschach",
        parameters: .init(beatPulse: 0.28, diffusionSoftness: 0.22,
                          bilateralSymmetry: 1, halftoneGrating: 76),
        audioMapping: .init(energyToBrightness: 0.03, beatToPulse: 0.45))

    /// "liquid-dream" (a Marble recipe) was removed: the Liquid Dream
    /// experience uses `glassSurface`, and nothing else referenced it.
    static let all = [originalMarble, cyberChrome, neonPulse,
                      glassSurface, chromeNight, organicPulse, smoke, advancedMarble,
                      agateZebra, voidGloss, terrazzoMagma, airbrushMirage,
                      grooveEbru, cymaticRorschach]
}
