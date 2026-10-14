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


// MARK: - Stage 19A.1: pure song-aware selection

/// A metadata policy, NOT a key detector or a second audio/visual engine.
/// It accepts only source-matched, available evidence; empty/unreliable caches
/// keep the established Original recipe and the existing 7-sample drum kit.
enum SongCreativeProfileResolver {
    static func suggest(assetID: String, sourceRevision: String,
                        analysis: MusicAnalysisResult?,
                        expression: MusicExpressionResult?) -> SongCreativeProfile {
        let rhythm = (analysis?.assetID == assetID &&
                      analysis?.sourceRevision == sourceRevision &&
                      analysis?.capabilities[.rhythm] == .available)
            ? analysis?.rhythmAnalysis : nil
        let tempo: Double? = {
            guard let rhythm, rhythm.quality == .medium || rhythm.quality == .high,
                  let first = rhythm.bpmCandidates.first,
                  first.confidence >= 0.60, first.bpm.isFinite,
                  (55...210).contains(first.bpm) else { return nil }
            return first.bpm
        }()

        let matched = expression?.assetID == assetID &&
            expression?.sourceRevision == sourceRevision
        let key = (matched && expression?.capabilities[.key] == .available)
            ? expression?.key : nil
        let tonic: MusicalPitchClass? = {
            guard let key, key.confidence >= 0.70 else { return nil }
            return key.key
        }()
        let scale = tonic == nil ? nil : key?.scale
        let hints = (matched && expression?.capabilities[.moodHints] == .available)
            ? expression?.moodHints?.hints : nil
        func hint(_ type: MoodDimension) -> Double? {
            hints?.first {
                $0.dimension == type && $0.confidence >= 0.60 &&
                $0.normalizedValue.isFinite
            }?.normalizedValue
        }
        let density = hint(.rhythmicDensity)
        let brightness = hint(.spectralBrightness)

        let selection: String
        if (density ?? 0) >= 0.70 || (tempo ?? 0) >= 145 {
            selection = "neon-pulse"
        } else if let brightness, brightness < 0.38 {
            selection = "liquid-dream"
        } else if density != nil || brightness != nil {
            selection = "cyber-night"
        } else {
            selection = CreativePresetCatalog.defaultID
        }

        let typography = CreativePresetCatalog.selectedExperience(id: selection)?
            .typographyPreset ?? TypographyPreset(
                style: CreativePresetCatalog.recipe(for: selection)
                    .preset.typographyStyle)
        let mapping = SongPadGuardrails(
            bpm: tempo, tonic: tonic, scale: scale,
            subdivision: (tempo ?? 0) >= 145 ? 2 : 1,
            melodicPadTuningActive: false)
        return SongCreativeProfile(
            assetID: assetID, sourceRevision: sourceRevision,
            visualPresetID: selection,
            materialID: CreativePresetCatalog.material(selection: selection).id,
            typographyPreset: typography, padMapping: mapping,
            vocalAndAudioFXMacro: brightness.map { 0.15 + (1 - $0) * 0.25 } ?? 0,
            reactionProfile: (density ?? 0) > 0.65 ? .responsive : .subtle)
    }

    /// Frozen controls are chosen once when the user taps "Criar", not inside
    /// TimelineView and never on an audio render callback.
    static func creatorPreset(for profile: SongCreativeProfile,
                              preserving previous: CreatorPreset? = nil) -> CreatorPreset {
        CreatorPreset(
            experienceID: profile.visualPresetID,
            materialID: profile.materialID,
            typography: profile.typographyPreset,
            controls: previous?.controls ?? .neutral,
            exportProfile: previous?.exportProfile ?? ExportProfile(),
            songProfile: profile)
    }
}
