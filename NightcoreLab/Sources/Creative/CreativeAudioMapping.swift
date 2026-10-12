import Foundation

/// Stage 9 uses only the existing AudioFeatures sample; frequency is the
/// normalized high-frequency (treble) BAND, not fundamental pitch or FFT Hz.
enum CreativeExperienceAudioSignal: String, Codable, CaseIterable, Sendable {
    case bass, energy, beat, frequency

    func sample(_ features: AudioFeatures?) -> Double {
        guard let features else { return 0 }
        switch self {
        case .bass: return Self.unit(features.bass)
        case .energy: return Self.unit(features.energy)
        case .beat: return features.beatDetected ? 1 : 0
        case .frequency: return Self.unit(features.treble)
        }
    }

    private static func unit(_ value: Double) -> Double {
        guard value.isFinite else { return 0 }
        return min(1, max(0, value))
    }
}

enum CreativeExperienceAudioTarget: String, Codable, CaseIterable, Sendable {
    case visualIntensity, typographyIntensity, movement
}

struct CreativeExperienceAudioBinding: Codable, Equatable, Sendable {
    let signal: CreativeExperienceAudioSignal
    let target: CreativeExperienceAudioTarget
    let gain: Double

    init(signal: CreativeExperienceAudioSignal,
         target: CreativeExperienceAudioTarget, gain: Double) {
        self.signal = signal
        self.target = target
        self.gain = gain
    }

    var isValid: Bool { gain.isFinite && (0...1).contains(gain) }
}

/// Opt-in experience-level envelope, supplementary to the EXISTING
/// CreativeEquation/LayerAudioBinding/ TypographyAudioMapping contracts.
/// No duplicate equations, untyped key paths, audio-engine reads or shaders.
struct CreativeAudioMapping: Codable, Equatable, Sendable {
    let enabled: Bool
    let bindings: [CreativeExperienceAudioBinding]

    static let disabled = CreativeAudioMapping(enabled: false, bindings: [])

    init(enabled: Bool = false,
         bindings: [CreativeExperienceAudioBinding] = []) {
        self.enabled = enabled
        self.bindings = bindings
    }

    var isValid: Bool {
        bindings.count <= 12 &&
        bindings.allSatisfy(\.isValid) &&
        Set(bindings.map { $0.signal.rawValue + ":" + $0.target.rawValue }).count
            == bindings.count
    }

    private enum CodingKeys: String, CodingKey {
        case enabled, bindings
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let enabled = try c.decode(Bool.self, forKey: .enabled)
        let bindings = try c.decode([CreativeExperienceAudioBinding].self,
                                    forKey: .bindings)
        self.init(enabled: enabled, bindings: bindings)
        guard isValid else {
            throw DecodingError.dataCorrupted(.init(
                codingPath: decoder.codingPath,
                debugDescription: "Invalid or duplicate experience audio bindings"))
        }
    }

    func resolve(features: AudioFeatures?) -> CreativeAudioState {
        guard enabled, isValid else { return .neutral }
        func amount(_ target: CreativeExperienceAudioTarget) -> Double {
            let sum = bindings.reduce(0.0) { partial, binding in
                partial + (binding.target == target
                    ? binding.gain * binding.signal.sample(features) : 0)
            }
            return min(1, max(0, sum))
        }
        return CreativeAudioState(
            visualIntensity: amount(.visualIntensity),
            typographyIntensity: amount(.typographyIntensity),
            movement: amount(.movement))
    }
}

struct CreativeAudioState: Equatable, Sendable {
    let visualIntensity: Double
    let typographyIntensity: Double
    let movement: Double

    static let neutral = CreativeAudioState(
        visualIntensity: 0, typographyIntensity: 0, movement: 0)
}
