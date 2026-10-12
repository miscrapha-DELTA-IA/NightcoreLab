import Foundation

/// Four parameter recipes, all using the existing liquidMarble shader.
/// Chrome/Liquid are artistic names, not new rendering algorithms.
enum VisualMaterialCatalog {
    static let originalMarble = VisualMaterial.legacyMarble
    static let cyberChrome = VisualMaterial(
        id: "cyber-chrome", name: "Cyber Chrome",
        parameters: .init(beatPulse: 0.6, pulseDecay: 9, offbeatScale: 0.5,
                          warpAmount: 0.12, brightnessBoost: 0.12),
        audioMapping: .init(bassToDistortion: 0.16, energyToBrightness: 0.06,
                            downbeatToAccent: 0.08))
    static let liquidDream = VisualMaterial(
        id: "liquid-dream", name: "Liquid Dream",
        parameters: .init(beatPulse: 0.3, pulseDecay: 3, offbeatScale: 0.85,
                          warpAmount: 0.10, brightnessBoost: 0.06),
        audioMapping: .init(bassToDistortion: 0.08, energyToBrightness: 0.04,
                            downbeatToAccent: 0.03))
    static let neonPulse = VisualMaterial(
        id: "neon-pulse", name: "Neon Pulse",
        parameters: .init(beatPulse: 0.85, pulseDecay: 8, offbeatScale: 0.55,
                          warpAmount: 0.24, brightnessBoost: 0.12),
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
        audioMapping: .init(bassToDistortion: 0.1))
    static let smoke = VisualMaterial(
        id: "atmospheric-smoke", name: "Atmospheric Smoke", type: .atmosphericSmoke,
        parameters: .init(beatPulse: 0.2, pulseDecay: 5),
        audioMapping: .init(energyToBrightness: 0.06))
    static let advancedMarble = VisualMaterial(
        id: "advanced-marble", name: "Advanced Marble", type: .advancedMarble,
        parameters: .init(beatPulse: 0.6, pulseDecay: 6),
        audioMapping: .init(bassToDistortion: 0.10))
    static let all = [originalMarble, cyberChrome, liquidDream, neonPulse,
                      glassSurface, chromeNight, organicPulse, smoke, advancedMarble]
}
