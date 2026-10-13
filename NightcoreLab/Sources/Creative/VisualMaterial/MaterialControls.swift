import Foundation

/// Four normalized controls shared by all nonlegacy Metal materials.
enum MaterialAudioSignal: String, CaseIterable, Sendable {
    case beat, energy, bass, movement, brightness
}
struct MaterialControls: Codable, Equatable, Sendable {
    let primary: Double
    let secondary: Double
    let tertiary: Double
    let quaternary: Double
    init(_ a: Double, _ b: Double, _ c: Double, _ d: Double) {
        primary = materialBound(a, 0...1); secondary = materialBound(b, 0...1)
        tertiary = materialBound(c, 0...1); quaternary = materialBound(d, 0...1)
    }
    static func liquidGlass(glassAmount: Double = 0.7, distortion: Double = 0.4,
                            refraction: Double = 0.5, surfaceNoise: Double = 0.3) -> Self {
        Self(glassAmount, distortion, refraction, surfaceNoise)
    }
    static func chrome(metalness: Double = 0.9, reflection: Double = 0.7,
                       brightness: Double = 0.55, contrast: Double = 0.75) -> Self {
        Self(metalness, reflection, brightness, contrast)
    }
    static func organicNoise(noiseScale: Double = 0.5, turbulence: Double = 0.6,
                             flowSpeed: Double = 0.4, density: Double = 0.65) -> Self {
        Self(noiseScale, turbulence, flowSpeed, density)
    }
    static func atmosphericSmoke(density: Double = 0.6, turbulence: Double = 0.35,
                                 drift: Double = 0.3, opacity: Double = 0.65) -> Self {
        Self(density, turbulence, drift, opacity)
    }
    static func advancedMarble(layers: Double = 0.6, intensity: Double = 0.6,
                               contrast: Double = 0.65, veinWidth: Double = 0.5) -> Self {
        Self(layers, intensity, contrast, veinWidth)
    }
    static func defaults(for type: VisualMaterialType) -> Self {
        switch type {
        case .liquidGlass: return .liquidGlass()
        case .chrome: return .chrome()
        case .organicNoise: return .organicNoise()
        case .atmosphericSmoke: return .atmosphericSmoke()
        case .advancedMarble: return .advancedMarble()
        default: return Self(0, 0, 0, 0)
        }
    }
    private enum CodingKeys: String, CodingKey {
        case primary, secondary, tertiary, quaternary
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(try c.decode(Double.self, forKey: .primary),
                  try c.decode(Double.self, forKey: .secondary),
                  try c.decode(Double.self, forKey: .tertiary),
                  try c.decode(Double.self, forKey: .quaternary))
    }
}
