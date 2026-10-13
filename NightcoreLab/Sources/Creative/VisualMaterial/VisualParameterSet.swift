import Foundation

/// The single Marble parameter contract (Stage 13 consolidation):
/// - authored on `VisualMaterial.parameters` (look, reaction-free);
/// - resolved per frame in `MaterialFrame.parameters`;
/// - bound to the shader as `MarbleUniforms` (a typealias of this type).
/// Existing shader vocabulary only. No textures, dynamic dictionaries or renderer state.
struct VisualParameterSet: Codable, Equatable, Sendable {
    static let neutral = VisualParameterSet()

    let distortion: Double
    let beatPulse: Double
    let pulseDecay: Double
    let offbeatScale: Double
    let warpAmount: Double
    let brightnessBoost: Double

    init(distortion: Double = 0,
         beatPulse: Double = 0,
         pulseDecay: Double = 6,
         offbeatScale: Double = 0.7,
         warpAmount: Double = 0.18,
         brightnessBoost: Double = 0.1) {
        self.distortion = materialBound(distortion, 0...1, fallback: 0)
        self.beatPulse = materialBound(beatPulse, 0...1, fallback: 0)
        self.pulseDecay = materialBound(pulseDecay, 1...20, fallback: 6)
        self.offbeatScale = materialBound(offbeatScale, 0...1, fallback: 0.7)
        self.warpAmount = materialBound(warpAmount, 0...0.5, fallback: 0.18)
        self.brightnessBoost = materialBound(brightnessBoost, 0...0.3, fallback: 0.1)
    }

    private enum CodingKeys: String, CodingKey {
        case distortion, beatPulse, pulseDecay, offbeatScale, warpAmount, brightnessBoost
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            distortion: try c.decodeIfPresent(Double.self, forKey: .distortion) ?? 0,
            beatPulse: try c.decodeIfPresent(Double.self, forKey: .beatPulse) ?? 0,
            pulseDecay: try c.decodeIfPresent(Double.self, forKey: .pulseDecay) ?? 6,
            offbeatScale: try c.decodeIfPresent(Double.self, forKey: .offbeatScale) ?? 0.7,
            warpAmount: try c.decodeIfPresent(Double.self, forKey: .warpAmount) ?? 0.18,
            brightnessBoost: try c.decodeIfPresent(Double.self, forKey: .brightnessBoost) ?? 0.1)
    }
}

/// Shared numeric boundary, also applied while decoding external presets.
func materialBound(_ value: Double, _ range: ClosedRange<Double>, fallback: Double = 0) -> Double {
    value.isFinite ? min(range.upperBound, max(range.lowerBound, value)) : fallback
}
