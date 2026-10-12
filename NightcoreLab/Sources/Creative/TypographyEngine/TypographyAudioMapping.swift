import Foundation

enum TypographyAudioSignal: String, Codable, Sendable {
    case beat, bass, energy

    func sample(_ features: AudioFeatures?) -> Double {
        guard let features else { return 0 }
        switch self {
        case .beat: return features.beatDetected ? 1 : 0
        case .bass: return Self.unit(features.bass)
        case .energy: return Self.unit(features.energy)
        }
    }

    private static func unit(_ value: Double) -> Double {
        guard value.isFinite else { return 0 }
        return min(1, max(0, value))
    }
}

enum TypographyAudioTarget: String, Codable, Sendable {
    case scale, glow, movement
}

struct TypographyAudioBinding: Codable, Equatable, Sendable {
    let signal: TypographyAudioSignal
    let target: TypographyAudioTarget
    let gain: Double

    var isValid: Bool { gain.isFinite && (0...0.5).contains(gain) }
}

/// Opt-in typed mappings; no arbitrary property names, scripting or shaders.
struct TypographyAudioMapping: Codable, Equatable, Sendable {
    let bindings: [TypographyAudioBinding]

    init(bindings: [TypographyAudioBinding] = []) {
        self.bindings = bindings
    }

    /// Mirrors Stage 6's opt-in baseline (beat 4%, energy 18%, bass 7%).
    static let legacy = TypographyAudioMapping(bindings: [
        .init(signal: .beat, target: .scale, gain: 0.04),
        .init(signal: .energy, target: .glow, gain: 0.18),
        .init(signal: .bass, target: .glow, gain: 0.07)
    ])

    static let kinetic = TypographyAudioMapping(bindings: [
        .init(signal: .beat, target: .scale, gain: 0.04),
        .init(signal: .energy, target: .glow, gain: 0.18),
        .init(signal: .bass, target: .glow, gain: 0.07),
        .init(signal: .bass, target: .movement, gain: 0.035),
        .init(signal: .energy, target: .movement, gain: 0.025)
    ])

    var isValid: Bool {
        bindings.count <= 12 && bindings.allSatisfy(\.isValid) &&
        Set(bindings.map { $0.signal.rawValue + ":" + $0.target.rawValue }).count == bindings.count
    }

    func amount(for target: TypographyAudioTarget, features: AudioFeatures?,
                reaction: TypographyAudioReaction) -> Double {
        guard reaction != .off, isValid else { return 0 }
        let raw = bindings
            .filter { $0.target == target }
            .reduce(0.0) { $0 + $1.signal.sample(features) * $1.gain }
        return min(0.5, max(0, raw * reaction.gain))
    }
}
