import Foundation

/// Stage 13 shader contract extended additively in EXP-7.
/// Zero texture modifiers are strictly identical to the legacy Marble.
struct VisualParameterSet: Codable, Equatable, Sendable {
    static let neutral = VisualParameterSet()
    let distortion: Double
    let beatPulse: Double
    let pulseDecay: Double
    let offbeatScale: Double
    let warpAmount: Double
    let brightnessBoost: Double
    // Purely visual, author-time texture controls (never modulated by FFT).
    let stripingFrequency: Double
    let stripingMix: Double
    let speckleIntensity: Double
    let embossStrength: Double
    let scanlineDensity: Double
    let diffusionSoftness: Double
    let voidThreshold: Double
    let combStretch: Double
    let bilateralSymmetry: Double
    let halftoneGrating: Double

    var usesProceduralTexture: Bool {
        stripingMix > 0 || speckleIntensity > 0 || embossStrength > 0 ||
        scanlineDensity > 0 || diffusionSoftness > 0 || voidThreshold > 0 ||
        combStretch > 0 || bilateralSymmetry > 0 || halftoneGrating > 0
    }

    init(distortion: Double = 0, beatPulse: Double = 0,
         pulseDecay: Double = 6, offbeatScale: Double = 0.7,
         warpAmount: Double = 0.18, brightnessBoost: Double = 0.1,
         stripingFrequency: Double = 0,
         stripingMix: Double = 0,
         speckleIntensity: Double = 0,
         embossStrength: Double = 0,
         scanlineDensity: Double = 0,
         diffusionSoftness: Double = 0,
         voidThreshold: Double = 0,
         combStretch: Double = 0,
         bilateralSymmetry: Double = 0,
         halftoneGrating: Double = 0) {
        self.distortion = materialBound(distortion, 0...1, fallback: 0)
        self.beatPulse = materialBound(beatPulse, 0...1, fallback: 0)
        self.pulseDecay = materialBound(pulseDecay, 1...20, fallback: 6)
        self.offbeatScale = materialBound(offbeatScale, 0...1, fallback: 0.7)
        self.warpAmount = materialBound(warpAmount, 0...0.5, fallback: 0.18)
        self.brightnessBoost = materialBound(brightnessBoost, 0...0.3, fallback: 0.1)
        self.stripingFrequency = materialBound(stripingFrequency, 0...80, fallback: 0)
        self.stripingMix = materialBound(stripingMix, 0...1, fallback: 0)
        self.speckleIntensity = materialBound(speckleIntensity, 0...1, fallback: 0)
        self.embossStrength = materialBound(embossStrength, 0...1, fallback: 0)
        self.scanlineDensity = materialBound(scanlineDensity, 0...160, fallback: 0)
        self.diffusionSoftness = materialBound(diffusionSoftness, 0...1, fallback: 0)
        self.voidThreshold = materialBound(voidThreshold, 0...1, fallback: 0)
        self.combStretch = materialBound(combStretch, 0...8, fallback: 0)
        self.bilateralSymmetry = materialBound(bilateralSymmetry, 0...1, fallback: 0)
        self.halftoneGrating = materialBound(halftoneGrating, 0...120, fallback: 0)
    }

    private enum CodingKeys: String, CodingKey {
        case distortion, beatPulse, pulseDecay, offbeatScale, warpAmount, brightnessBoost
        case stripingFrequency, stripingMix, speckleIntensity, embossStrength, scanlineDensity, diffusionSoftness, voidThreshold, combStretch, bilateralSymmetry, halftoneGrating
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            distortion: try c.decodeIfPresent(Double.self, forKey: .distortion) ?? 0,
            beatPulse: try c.decodeIfPresent(Double.self, forKey: .beatPulse) ?? 0,
            pulseDecay: try c.decodeIfPresent(Double.self, forKey: .pulseDecay) ?? 6,
            offbeatScale: try c.decodeIfPresent(Double.self, forKey: .offbeatScale) ?? 0.7,
            warpAmount: try c.decodeIfPresent(Double.self, forKey: .warpAmount) ?? 0.18,
            brightnessBoost: try c.decodeIfPresent(Double.self, forKey: .brightnessBoost) ?? 0.1,
            stripingFrequency: try c.decodeIfPresent(Double.self, forKey: .stripingFrequency) ?? 0,
            stripingMix: try c.decodeIfPresent(Double.self, forKey: .stripingMix) ?? 0,
            speckleIntensity: try c.decodeIfPresent(Double.self, forKey: .speckleIntensity) ?? 0,
            embossStrength: try c.decodeIfPresent(Double.self, forKey: .embossStrength) ?? 0,
            scanlineDensity: try c.decodeIfPresent(Double.self, forKey: .scanlineDensity) ?? 0,
            diffusionSoftness: try c.decodeIfPresent(Double.self, forKey: .diffusionSoftness) ?? 0,
            voidThreshold: try c.decodeIfPresent(Double.self, forKey: .voidThreshold) ?? 0,
            combStretch: try c.decodeIfPresent(Double.self, forKey: .combStretch) ?? 0,
            bilateralSymmetry: try c.decodeIfPresent(Double.self, forKey: .bilateralSymmetry) ?? 0,
            halftoneGrating: try c.decodeIfPresent(Double.self, forKey: .halftoneGrating) ?? 0)
    }
}

/// Shared numeric boundary, also applied while decoding external presets.
func materialBound(_ value: Double, _ range: ClosedRange<Double>, fallback: Double = 0) -> Double {
    value.isFinite ? min(range.upperBound, max(range.lowerBound, value)) : fallback
}
