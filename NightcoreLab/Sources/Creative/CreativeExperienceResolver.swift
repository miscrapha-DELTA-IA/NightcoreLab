import Foundation

/// A pure, stateless coordinator. No UI, AVAudioEngine, clock, networking,
/// cache mutation, renderer or RNG. Always resolves the SAME composition core.
enum CreativeExperienceResolver {
    /// THE material rule (Experience → Material). Every consumer — the live
    /// player, the Story request, the runtime default and the catalog —
    /// asks here; no View or renderer chooses a material.
    /// An experience's authored material wins; otherwise the reaction-free
    /// Marble derived from its program (or from the recipe when there is no
    /// experience); with neither, the original Marble.
    static func material(experience: CreativeExperiencePreset?,
                         recipe: CreativeVisualProgram? = nil) -> VisualMaterial {
        if let authored = experience?.material { return authored }
        return .marble(for: experience?.composition.program ?? recipe)
    }

    /// `runtime`: pass the frozen runtime when one exists (render paths) so the
    /// composition is not recompiled per call; it must match the preset.
    static func resolve(_ preset: CreativeExperiencePreset,
                        elapsed: TimeInterval,
                        features: AudioFeatures? = nil,
                        typography: TypographyLayer? = nil,
                        rhythm: RhythmFrame? = nil,
                        runtime frozen: CompositionRuntime? = nil) -> CreativeExperienceFrame? {
        guard preset.isValid else { return nil }
        let audioState = preset.audioMapping.resolve(features: features)

        // Composition carries the existing CreativeVisualProgram and rules.
        // The experience mapping is an additional explicit authoring channel:
        // never multiply or silently overwrite the legacy Marble parameters.
        let effectiveTypography: TypographyLayer? = typography.map { input in
            // Same envelope as the karaoke and Story (TypographyPreset.modulated).
            let mapped = preset.typographyPreset.modulated(
                by: preset.audioMapping, features: features)
            return TypographyLayer(
                layerID: input.layerID, state: input.state,
                preset: mapped, lyricOffset: input.lyricOffset,
                prepared: input.prepared)
        }

        let runtime: CompositionRuntime
        if let frozen, frozen.composition == preset.composition,
           frozen.material == preset.visualMaterial {
            runtime = frozen
        } else {
            runtime = CompositionRuntime(composition: preset.composition,
                                         material: preset.visualMaterial)
        }
        guard let compositionFrame = runtime.frame(
            at: elapsed, features: features, typography: effectiveTypography, rhythm: rhythm) else {
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
