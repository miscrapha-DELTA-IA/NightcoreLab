import Foundation

/// O(1) pure value mapping. No clock, random generator, cache, Metal or history.
/// Reserved types explicitly fall back to Original Marble until implemented.
enum MaterialResolver {
    static func resolve(_ material: VisualMaterial,
                        features: AudioFeatures? = nil,
                        rhythm: RhythmFrame? = nil,
                        timestamp: TimeInterval,
                        parameters: CreativeParameterFrame = .neutral,
                        reactionGain: Double = 1,
                        seed: UInt64 = 0) -> MaterialFrame {
        let material = material.type.isSupported ? material : .legacyMarble
        let validTime = timestamp.isFinite && timestamp >= 0
        let gain = validTime ? materialBound(reactionGain, 0...1) : 0
        let features = validTime ? features : nil
        let rhythm = validTime ? rhythm : nil
        let mapping = material.audioMapping
        let amount = material.intensity * gain
        // One audio route per frame (CreativeReactionProfile): program rules
        // for recipes, the authored mapping for experience materials.
        let route = CreativeReactionProfile.materialRoute(for: material)
        let programDistortion = route == .program && validTime
            ? materialBound(parameters.marbleDistortion, 0...1) : 0
        let bass = materialBound((features?.bass ?? 0) * mapping.bassToDistortion * amount, 0...1)
        let energy = materialBound((features?.energy ?? 0) * mapping.energyToBrightness * amount, 0...0.3)
        let pulse = beatPulse(material, rhythm: rhythm) * gain
        let accent: Double
        if let rhythm, rhythm.barBeat == 0,
           rhythm.downbeatConfidence >= Float(mapping.downbeatThreshold) {
            accent = materialBound(mapping.downbeatToAccent * amount * trust(material, rhythm)
                                   * rhythm.pulse(decay: material.pulseDecay), 0...0.3)
        } else { accent = 0 }
        let resolved = VisualParameterSet(
            distortion: material.parameters.distortion + programDistortion + bass,
            beatPulse: pulse, pulseDecay: material.pulseDecay,
            offbeatScale: material.offbeatScale, warpAmount: material.warpAmount,
            brightnessBoost: material.brightnessBoost + energy + accent)
        let activeFeatures = gain > 0 ? features : nil
        let allowed = material.type.acceptedSignals
        func accepts(_ input: MaterialAudioSignal) -> Bool { allowed.contains(input) }
        let signals = MaterialReactiveSignals(
            energy: accepts(.energy) ? materialBound(activeFeatures?.energy ?? 0, 0...1) : 0,
            bass: accepts(.bass) ? materialBound(activeFeatures?.bass ?? 0, 0...1) : 0,
            // From the material mapping only (one route; no program kinetics).
            movement: accepts(.movement)
                ? materialBound((features?.energy ?? 0) * mapping.energyToMovement * amount, 0...1) : 0,
            brightness: accepts(.brightness) ? materialBound(activeFeatures?.treble ?? 0, 0...1) : 0)
        return MaterialFrame(
            materialID: material.id, type: material.type, parameters: resolved,
            intensity: material.intensity,
            audioResponse: MaterialAudioResponse(distortion: bass, brightness: energy,
                                                  pulse: pulse, accent: accent),
            timestamp: validTime ? timestamp : 0,
            seed: seed, controls: material.controls, signals: signals)
    }

    /// Compatibility projection for Stage 12 callers; one mapping implementation.
    static func marble(_ material: VisualMaterial,
                       parameters: CreativeParameterFrame,
                       rhythm: RhythmFrame?) -> MarbleUniforms {
        resolve(material, rhythm: rhythm, timestamp: 0,
                parameters: parameters).marbleUniforms
    }

    /// Original multiplication order retained for bit-exact default uniforms.
    static func beatPulse(_ material: VisualMaterial, rhythm: RhythmFrame?) -> Double {
        guard material.type.isSupported, material.beatPulse > 0, let rhythm else { return 0 }
        let trust = trust(material, rhythm)
        guard trust > 0 else { return 0 }
        var accent = 1.0
        if let barBeat = rhythm.barBeat,
           rhythm.downbeatConfidence >= Float(material.audioMapping.downbeatThreshold),
           barBeat != 0 {
            accent = material.offbeatScale
        }
        let legacy = materialBound(material.beatPulse * trust * accent *
                                   rhythm.pulse(decay: material.pulseDecay), 0...1)
        return materialBound(legacy * material.audioMapping.beatToPulse * material.intensity, 0...1)
    }

    private static func trust(_ material: VisualMaterial, _ rhythm: RhythmFrame) -> Double {
        materialBound((Double(rhythm.confidence) - material.audioMapping.confidenceFloor)
                      / material.audioMapping.confidenceRange, 0...1)
    }
}
