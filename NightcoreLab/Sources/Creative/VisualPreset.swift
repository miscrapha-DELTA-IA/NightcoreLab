import Foundation

/// Serializable description only: shaders and effects are NOT changed in Phase 1.
struct VisualPreset: Codable, Equatable, Sendable {
    enum Background: String, Codable, CaseIterable, Sendable {
        case marble
        case blurredArtwork
        case sharpArtwork
        case marqueeArtwork
        case nativeTurbulence
    }

    struct ShaderParameters: Codable, Equatable, Sendable {
        /// Future parameters: no binding to Shaders.metal in this phase.
        let timeScale: Double
        let distortion: Double
        let glow: Double

        init(timeScale: Double = 1, distortion: Double = 0.5, glow: Double = 0.5) {
            self.timeScale = Self.unit(timeScale)
            self.distortion = Self.unit(distortion)
            self.glow = Self.unit(glow)
        }

        private static func unit(_ value: Double) -> Double {
            guard value.isFinite else { return 0 }
            return min(max(value, 0), 1)
        }

        private enum CodingKeys: String, CodingKey {
            case timeScale, distortion, glow
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            self.init(timeScale: try c.decode(Double.self, forKey: .timeScale),
                      distortion: try c.decode(Double.self, forKey: .distortion),
                      glow: try c.decode(Double.self, forKey: .glow))
        }
    }

    let background: Background
    let shaderParameters: ShaderParameters
    let intensity: Double
    let motion: Double

    init(background: Background = .marble,
         shaderParameters: ShaderParameters = ShaderParameters(),
         intensity: Double = 1, motion: Double = 0.5) {
        self.background = background
        self.shaderParameters = shaderParameters
        self.intensity = Self.unit(intensity)
        self.motion = Self.unit(motion)
    }

    private static func unit(_ value: Double) -> Double {
        guard value.isFinite else { return 0 }
        return min(max(value, 0), 1)
    }

    private enum CodingKeys: String, CodingKey {
        case background, shaderParameters, intensity, motion
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(background: try c.decode(Background.self, forKey: .background),
                  shaderParameters: try c.decode(ShaderParameters.self, forKey: .shaderParameters),
                  intensity: try c.decode(Double.self, forKey: .intensity),
                  motion: try c.decode(Double.self, forKey: .motion))
    }
}

/// Read-only compatibility adapter: maps existing player appearance into a
/// preset description without touching PlayerBackgroundView or its animations.
extension VisualPreset.Background {
    init(existing style: PlayerBackgroundStyle) {
        switch style {
        case .blurred: self = .blurredArtwork
        case .sharp: self = .sharpArtwork
        case .marquee: self = .marqueeArtwork
        case .turbulent: self = .marble
        }
    }
}
