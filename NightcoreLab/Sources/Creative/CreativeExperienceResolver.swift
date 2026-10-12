import Foundation

/// A pure, stateless coordinator. No UI, AVAudioEngine, clock, networking,
/// cache mutation, renderer or RNG. Always resolves the SAME composition core.
enum CreativeExperienceResolver {
    static func resolve(_ preset: CreativeExperiencePreset,
                        elapsed: TimeInterval,
                        features: AudioFeatures? = nil,
                        typography: TypographyLayer? = nil) -> CreativeExperienceFrame? {
        guard preset.isValid else { return nil }
        let audioState = preset.audioMapping.resolve(features: features)

        // Composition carries the existing CreativeVisualProgram and rules.
        // The experience mapping is an additional explicit authoring channel:
        // never multiply or silently overwrite the legacy Marble parameters.
        let effectiveTypography: TypographyLayer? = typography.map { input in
            let authored = preset.typographyPreset
            let intensity = min(1, authored.effectIntensity +
                                audioState.typographyIntensity)
            let mapped = TypographyPreset(
                style: authored.style,
                audioReaction: authored.audioReaction,
                effectIntensity: intensity,
                audioMapping: authored.audioMapping,
                deterministicSeed: authored.deterministicSeed)
            return TypographyLayer(
                layerID: input.layerID, state: input.state,
                preset: mapped, lyricOffset: input.lyricOffset)
        }

        let runtime = CompositionRuntime(composition: preset.composition)
        guard let compositionFrame = runtime.frame(
            at: elapsed, features: features, typography: effectiveTypography) else {
            return nil
        }

        let visualFrame = CreativeExperienceVisualFrame(
            parameters: compositionFrame.programParameters,
            intensity: min(1, preset.visualPreset.intensity +
                           audioState.visualIntensity),
            movement: min(1, preset.visualPreset.motion + audioState.movement))

        return CreativeExperienceFrame(
            experienceID: preset.id, visualFrame: visualFrame,
            typographyFrame: compositionFrame.typographyFrame,
            compositionFrame: compositionFrame, audioState: audioState)
    }
}
