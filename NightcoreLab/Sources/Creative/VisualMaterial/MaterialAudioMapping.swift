import Foundation

/// Fixed audio routes. Gains and trust gates are authored data, never hidden in a shader.
struct MaterialAudioMapping: Codable, Equatable, Sendable {
    let bassToDistortion: Double
    let energyToBrightness: Double
    let beatToPulse: Double
    let downbeatToAccent: Double
    let confidenceFloor: Double
    let confidenceRange: Double
    let downbeatThreshold: Double

    static let legacy = MaterialAudioMapping()

    init(bassToDistortion: Double = 0,
         energyToBrightness: Double = 0,
         beatToPulse: Double = 1,
         downbeatToAccent: Double = 0,
         confidenceFloor: Double = 0.25,
         confidenceRange: Double = 0.5,
         downbeatThreshold: Double = 0.3) {
        self.bassToDistortion = materialBound(bassToDistortion, 0...1, fallback: 0)
        self.energyToBrightness = materialBound(energyToBrightness, 0...0.3, fallback: 0)
        self.beatToPulse = materialBound(beatToPulse, 0...1, fallback: 1)
        self.downbeatToAccent = materialBound(downbeatToAccent, 0...0.3, fallback: 0)
        self.confidenceFloor = materialBound(confidenceFloor, 0...1, fallback: 0.25)
        self.confidenceRange = materialBound(confidenceRange, 0.001...1, fallback: 0.5)
        self.downbeatThreshold = materialBound(downbeatThreshold, 0...1, fallback: 0.3)
    }

    private enum CodingKeys: String, CodingKey {
        case bassToDistortion, energyToBrightness, beatToPulse, downbeatToAccent, confidenceFloor, confidenceRange, downbeatThreshold
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            bassToDistortion: try c.decodeIfPresent(Double.self, forKey: .bassToDistortion) ?? 0,
            energyToBrightness: try c.decodeIfPresent(Double.self, forKey: .energyToBrightness) ?? 0,
            beatToPulse: try c.decodeIfPresent(Double.self, forKey: .beatToPulse) ?? 1,
            downbeatToAccent: try c.decodeIfPresent(Double.self, forKey: .downbeatToAccent) ?? 0,
            confidenceFloor: try c.decodeIfPresent(Double.self, forKey: .confidenceFloor) ?? 0.25,
            confidenceRange: try c.decodeIfPresent(Double.self, forKey: .confidenceRange) ?? 0.5,
            downbeatThreshold: try c.decodeIfPresent(Double.self, forKey: .downbeatThreshold) ?? 0.3)
    }
}
