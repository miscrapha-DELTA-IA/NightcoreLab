import Foundation

/// References the existing CreativeEquation and CreativeSignal vocabulary.
/// A binding targets a typed per-layer property, never a shader key path.
struct LayerAudioBinding: Codable, Equatable, Sendable {
    let property: LayerProperty
    let equation: CreativeEquation

    /// Identical replace/add/multiply semantics to CreativeParameterResolver,
    /// including its neutral/off and subtle-reaction rules. Only the target
    /// property type/bounds differ; no new expression language is introduced.
    func apply(to base: Double, features: AudioFeatures,
               sourceTime: TimeInterval, reaction: CreativePreset.AudioReaction) -> Double {
        guard reaction != .off, sourceTime.isFinite, sourceTime >= 0,
              features.energy > 0 || features.bass > 0 ||
              features.mid > 0 || features.treble > 0 else {
            return property.clamped(base)
        }
        let input = equation.signal.sample(
            features: features, sourceTime: sourceTime,
            frequency: equation.frequency, phase: equation.phase)
        let operand = equation.gain * input + equation.bias
        let gain = CreativeReactionProfile.gain(reaction)
        let value: Double
        switch equation.operation {
        case .replace: value = operand * gain
        case .add: value = base + operand * gain
        case .multiply: value = base * operand
        }
        return property.clamped(value)
    }
}
