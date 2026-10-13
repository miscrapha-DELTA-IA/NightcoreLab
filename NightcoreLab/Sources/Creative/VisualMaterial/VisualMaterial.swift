import Foundation

/// Reserved vocabulary; only Marble is renderable in Stage 13.
enum VisualMaterialType: String, Codable, CaseIterable, Sendable {
    case marble, liquid, glass, chrome, noise, fluid
    var isSupported: Bool { self == .marble }
}

/// Immutable authored data. Existing Stage 12/12.5 initializer and JSON keys
/// remain readable; the canonical Stage 13 representation is a parameter set.
struct VisualMaterial: Codable, Equatable, Sendable, Identifiable {
    typealias Kind = VisualMaterialType
    static let defaultPulseDecay = 6.0
    static let defaultOffbeatScale = 0.7
    static let defaultWarpAmount = 0.18
    static let defaultBrightnessBoost = 0.10
    static let programPulseScale = 0.8

    let id: String
    let name: String
    let type: VisualMaterialType
    let parameters: VisualParameterSet
    let intensity: Double
    let audioMapping: MaterialAudioMapping

    var kind: Kind { type }
    var beatPulse: Double { parameters.beatPulse }
    var beatPulseIntensity: Double { beatPulse }
    var pulseDecay: Double { parameters.pulseDecay }
    var offbeatScale: Double { parameters.offbeatScale }
    var downbeatBoost: Double { 1 - offbeatScale }
    var warpAmount: Double { parameters.warpAmount }
    var brightnessBoost: Double { parameters.brightnessBoost }

    init(id: String, name: String, type: VisualMaterialType = .marble,
         parameters: VisualParameterSet = .init(), intensity: Double = 1,
         audioMapping: MaterialAudioMapping = .legacy) {
        self.id = id
        self.name = name
        self.type = type
        self.parameters = parameters
        self.intensity = materialBound(intensity, 0...1, fallback: 1)
        self.audioMapping = audioMapping
    }

    init(kind: Kind = .marble, beatPulse: Double = 0,
         pulseDecay: Double = VisualMaterial.defaultPulseDecay,
         offbeatScale: Double = VisualMaterial.defaultOffbeatScale,
         warpAmount: Double = VisualMaterial.defaultWarpAmount,
         brightnessBoost: Double = VisualMaterial.defaultBrightnessBoost) {
        self.init(id: "original-marble", name: "Original Marble", type: kind,
                  parameters: .init(beatPulse: beatPulse, pulseDecay: pulseDecay,
                                    offbeatScale: offbeatScale, warpAmount: warpAmount,
                                    brightnessBoost: brightnessBoost))
    }

    init(beatPulseIntensity: Double,
         pulseDecay: Double = VisualMaterial.defaultPulseDecay,
         downbeatBoost: Double? = nil,
         warpAmount: Double = VisualMaterial.defaultWarpAmount,
         brightnessBoost: Double = VisualMaterial.defaultBrightnessBoost) {
        let offbeat = downbeatBoost.map {
            1 - materialBound($0, 0...1, fallback: 1 - Self.defaultOffbeatScale)
        } ?? Self.defaultOffbeatScale
        self.init(beatPulse: beatPulseIntensity, pulseDecay: pulseDecay,
                  offbeatScale: offbeat, warpAmount: warpAmount,
                  brightnessBoost: brightnessBoost)
    }

    static let legacyMarble = VisualMaterial()

    /// Reaction-free Marble derived from a recipe: the pulse amount follows
    /// the program's visual intensity. How much of it shows (Off / Subtle /
    /// Reactive) is applied once, at resolve time, by CreativeReactionProfile.
    static func marble(for program: CreativeVisualProgram?) -> VisualMaterial {
        guard let program else { return .legacyMarble }
        return VisualMaterial(beatPulse: programPulseScale * program.preset.visualStyle.intensity)
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, type, parameters, intensity, audioMapping
        case kind, beatPulse, pulseDecay, offbeatScale, warpAmount, brightnessBoost
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if c.contains(.parameters) {
            self.init(id: try c.decode(String.self, forKey: .id),
                      name: try c.decode(String.self, forKey: .name),
                      type: try c.decode(VisualMaterialType.self, forKey: .type),
                      parameters: try c.decode(VisualParameterSet.self, forKey: .parameters),
                      intensity: try c.decodeIfPresent(Double.self, forKey: .intensity) ?? 1,
                      audioMapping: try c.decodeIfPresent(MaterialAudioMapping.self,
                                                         forKey: .audioMapping) ?? .legacy)
        } else {
            self.init(kind: try c.decode(Kind.self, forKey: .kind),
                      beatPulse: try c.decode(Double.self, forKey: .beatPulse),
                      pulseDecay: try c.decodeIfPresent(Double.self, forKey: .pulseDecay)
                        ?? Self.defaultPulseDecay,
                      offbeatScale: try c.decodeIfPresent(Double.self, forKey: .offbeatScale)
                        ?? Self.defaultOffbeatScale,
                      warpAmount: try c.decodeIfPresent(Double.self, forKey: .warpAmount)
                        ?? Self.defaultWarpAmount,
                      brightnessBoost: try c.decodeIfPresent(Double.self, forKey: .brightnessBoost)
                        ?? Self.defaultBrightnessBoost)
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(type, forKey: .type)
        try c.encode(parameters, forKey: .parameters)
        try c.encode(intensity, forKey: .intensity)
        try c.encode(audioMapping, forKey: .audioMapping)
    }
}

/// The Marble shader's uniforms ARE a resolved VisualParameterSet: one
/// contract for authored material parameters, resolved frames and shader
/// bindings (no separately maintained struct). Source-compatible name.
typealias MarbleUniforms = VisualParameterSet
