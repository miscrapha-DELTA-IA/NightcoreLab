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
    /// "liquid-dream" (a Marble recipe) was removed: the Liquid Dream
    /// experience uses `glassSurface`, and nothing else referenced it.
    static let all = [originalMarble, cyberChrome, neonPulse,
                      glassSurface, chromeNight, organicPulse, smoke, advancedMarble]
}
