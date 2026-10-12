import Foundation

/// Declarative projectM-inspired modulation: no scripting, shader source,
/// reflection or expression evaluator accepting arbitrary user code.
enum CreativeSignal: String, Codable, Sendable, CaseIterable {
    case bass, mid, treble, energy, beat, timeSine

    func sample(features: AudioFeatures, sourceTime: TimeInterval,
                frequency: Double, phase: Double) -> Double {
        switch self {
        case .bass: return features.bass
        case .mid: return features.mid
        case .treble: return features.treble
        case .energy: return features.energy
        case .beat: return features.beatDetected ? 1 : 0
        case .timeSine:
            guard sourceTime.isFinite, sourceTime >= 0 else { return 0 }
            return 0.5 + 0.5 * sin(2 * .pi * frequency * sourceTime + phase)
        }
    }
}

enum CreativeEquationOperation: String, Codable, Sendable {
    case replace, add, multiply
}

/// A typed equation: base OP (gain * source + bias). All values are bounded
/// and decoded through the validating initializer. No dynamic executable AST.
struct CreativeEquation: Codable, Equatable, Sendable {
    let signal: CreativeSignal
    let operation: CreativeEquationOperation
    let gain: Double
    let bias: Double
    let frequency: Double
    let phase: Double

    init(signal: CreativeSignal, operation: CreativeEquationOperation = .replace,
         gain: Double = 1, bias: Double = 0,
         frequency: Double = 0.5, phase: Double = 0) {
        self.signal = signal
        self.operation = operation
        self.gain = Self.bound(gain, min: -2, max: 2, fallback: 0)
        self.bias = Self.bound(bias, min: -1, max: 1, fallback: 0)
        self.frequency = Self.bound(frequency, min: 0, max: 4, fallback: 0)
        self.phase = Self.bound(phase, min: -2 * .pi, max: 2 * .pi, fallback: 0)
    }

    private static func bound(_ x: Double, min lower: Double,
                              max upper: Double, fallback: Double) -> Double {
        x.isFinite ? Swift.min(upper, Swift.max(lower, x)) : fallback
    }

    private enum CodingKeys: String, CodingKey {
        case signal, operation, gain, bias, frequency, phase
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(signal: try c.decode(CreativeSignal.self, forKey: .signal),
                  operation: try c.decode(CreativeEquationOperation.self, forKey: .operation),
                  gain: try c.decode(Double.self, forKey: .gain),
                  bias: try c.decode(Double.self, forKey: .bias),
                  frequency: try c.decode(Double.self, forKey: .frequency),
                  phase: try c.decode(Double.self, forKey: .phase))
    }
}

struct CreativeParameterRule: Codable, Equatable, Sendable {
    let target: CreativeVisualTarget
    let equation: CreativeEquation
}

struct CreativeVisualProgram: Codable, Equatable, Sendable, Identifiable {
    static let supportedSchema = 1
    let schemaVersion: Int
    let preset: CreativePreset
    let rules: [CreativeParameterRule]
    var id: String { preset.id }

    init(preset: CreativePreset, rules: [CreativeParameterRule] = []) {
        self.schemaVersion = Self.supportedSchema
        self.preset = preset
        // Duplicate targets or >4 rules are always rejected on decoding;
        // the internal catalogue is authored once and statically audited.
        self.rules = rules
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, preset, rules
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let version = try c.decode(Int.self, forKey: .schemaVersion)
        let preset = try c.decode(CreativePreset.self, forKey: .preset)
        let rules = try c.decode([CreativeParameterRule].self, forKey: .rules)
        guard version == Self.supportedSchema, rules.count <= 4,
              Set(rules.map(\.target)).count == rules.count else {
            throw DecodingError.dataCorruptedError(
                forKey: .rules, in: c,
                debugDescription: "Unknown schema or repeated/excessive visual bindings")
        }
        self.init(preset: preset, rules: rules)
    }
}

/// Immutable evaluated values. The output never modifies SwiftUI or shaders.
struct CreativeParameterFrame: Equatable, Sendable {
    let playerGlow: Double
    let marbleDistortion: Double
    let lyricKinetics: Double
    let particleEmission: Double

    static let neutral = CreativeParameterFrame(
        playerGlow: 0, marbleDistortion: 0, lyricKinetics: 0, particleEmission: 0)

    func value(for target: CreativeVisualTarget) -> Double {
        switch target {
        case .playerGlow: return playerGlow
        case .marbleDistortion: return marbleDistortion
        case .lyricKinetics: return lyricKinetics
        case .particleEmission: return particleEmission
        }
    }
}

enum CreativeParameterResolver {
    /// Pure function shared by eventual realtime and timestamp-based export.
    /// Disabling audio reaction or silent input always restores neutral.
    static func resolve(program: CreativeVisualProgram,
                        response: VisualResponse,
                        features: AudioFeatures,
                        sourceTime: TimeInterval) -> CreativeParameterFrame {
        guard program.preset.audioReaction != .off,
              response != .neutral,
              features.energy > 0 || features.bass > 0 ||
              features.mid > 0 || features.treble > 0 else { return .neutral }
        let base = CreativeVisualBindings()
        func evaluated(_ target: CreativeVisualTarget) -> Double {
            let current = base.value(for: target, response: response)
            guard let rule = program.rules.first(where: { $0.target == target }) else {
                return current
            }
            let eq = rule.equation
            let reactionGain: Double = program.preset.audioReaction == .subtle ? 0.35 : 1
            let input = eq.signal.sample(features: features, sourceTime: sourceTime,
                                         frequency: eq.frequency, phase: eq.phase)
            let operand = eq.gain * input + eq.bias
            let raw: Double
            switch eq.operation {
            case .replace: raw = operand * reactionGain
            case .add: raw = current + operand * reactionGain
            case .multiply: raw = current * operand
            }
            guard raw.isFinite else { return 0 }
            return min(1, max(0, raw))
        }
        return CreativeParameterFrame(
            playerGlow: evaluated(.playerGlow),
            marbleDistortion: evaluated(.marbleDistortion),
            lyricKinetics: evaluated(.lyricKinetics),
            particleEmission: evaluated(.particleEmission))
    }
}
