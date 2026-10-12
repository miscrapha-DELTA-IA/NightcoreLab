import Foundation

/// Curated, versioned recipes. projectM's separation of presets and renderer,
/// adapted to the existing CreativePreset, VisualPreset and VisualResponse.
/// A catalogue selection does not silently change a user's AppTheme or
/// karaoke typography. Other visual targets remain descriptive until enabled.
enum CreativePresetCatalog {
    static let storageKey = "creativePresetID"
    static let defaultID = "original"

    static let all: [CreativeVisualProgram] = [
        CreativeVisualProgram(
            preset: CreativePreset(
                id: "original", name: "Original",
                theme: .acid, typographyStyle: .neon,
                visualStyle: VisualPreset(
                    background: .marble, intensity: 0.8, motion: 0.4),
                audioReaction: .responsive)),
        CreativeVisualProgram(
            preset: CreativePreset(
                id: "bass-pulse", name: "Bass Pulse",
                theme: .crimson, typographyStyle: .neon,
                visualStyle: VisualPreset(
                    background: .marble,
                    shaderParameters: .init(distortion: 0.75, glow: 0.85),
                    intensity: 0.95, motion: 0.6),
                audioReaction: .responsive),
            rules: [
                CreativeParameterRule(
                    target: .playerGlow,
                    equation: CreativeEquation(signal: .bass, gain: 1)),
                CreativeParameterRule(
                    target: .marbleDistortion,
                    equation: CreativeEquation(signal: .bass, gain: 0.7))
            ]),
        CreativeVisualProgram(
            preset: CreativePreset(
                id: "night-drive", name: "Night Drive",
                theme: .cyber, typographyStyle: .neon,
                visualStyle: VisualPreset(
                    background: .marble,
                    shaderParameters: .init(distortion: 0.4, glow: 0.8),
                    intensity: 0.65, motion: 0.35),
                audioReaction: .responsive),
            rules: [
                CreativeParameterRule(
                    target: .playerGlow,
                    equation: CreativeEquation(
                        signal: .energy, operation: .add, gain: 0.22)),
                CreativeParameterRule(
                    target: .lyricKinetics,
                    equation: CreativeEquation(
                        signal: .mid, operation: .multiply, gain: 0.6, bias: 0.4))
            ]),
        CreativeVisualProgram(
            preset: CreativePreset(
                id: "soft-flow", name: "Soft Flow",
                theme: .noir, typographyStyle: .magazineCutout,
                visualStyle: VisualPreset(
                    background: .marble,
                    shaderParameters: .init(distortion: 0.2, glow: 0.4),
                    intensity: 0.55, motion: 0.3),
                audioReaction: .responsive),
            rules: [
                CreativeParameterRule(
                    target: .playerGlow,
                    equation: CreativeEquation(
                        signal: .timeSine, operation: .multiply,
                        gain: 0.45, bias: 0.55, frequency: 0.3))
            ])
    ]

    static func program(for id: String) -> CreativeVisualProgram {
        all.first(where: { $0.id == id }) ?? all[0]
    }

    /// Preserve app-global theme/typography. The programme only describes
    /// reaction parameters and future visual targets; the current UI binds
    /// the player outline and the existing Marble distortion uniform.
    static func effectiveProgram(id: String, theme: AppTheme,
                                 typography: TypographyStyle,
                                 background: PlayerBackgroundStyle,
                                 reaction: CreativePreset.AudioReaction) -> CreativeVisualProgram {
        // Stage 12.5: an experience id resolves to the experience's own
        // program (same rules and shader vocabulary as its source recipe).
        let source = recipe(for: id)
        let configured = CreativePreset(
            id: source.id, name: source.preset.name,
            theme: theme, typographyStyle: typography,
            visualStyle: VisualPreset(
                background: .init(existing: background),
                shaderParameters: source.preset.visualStyle.shaderParameters,
                intensity: source.preset.visualStyle.intensity,
                motion: source.preset.visualStyle.motion),
            audioReaction: reaction)
        return CreativeVisualProgram(preset: configured, rules: source.rules)
    }
}


// MARK: - Stage 7 authoring packages (opt-in; original selection is unchanged)

extension CreativePresetCatalog {
    /// All four current recipes wrapped with their FULL visual programs.
    /// Template timeline is neutral; applying it to an actual asset will
    /// require a separately frozen composition/snapshot.
    static func builtInPackage(for id: String) -> CreativePresetPackage? {
        guard let program = all.first(where: { $0.id == id }),
              let timeline = try? CompositionTimeline(
                sourceStart: 0, playbackSpeed: 1, duration: 15) else {
            return nil
        }
        return try? CreativePresetPackage.wrap(
            program, author: "NightcoreLab", timeline: timeline)
    }

    /// Internal presets first, then locally authored packages in stable order.
    /// No network, account, marketplace, or application state mutation.
    static func availablePackages(
        from store: CreativePresetPackageStore) async -> [CreativePresetPackage] {
        let builtIns = all.compactMap { builtInPackage(for: $0.id) }
        let authored = await store.userPackages()
        return builtIns + authored
    }

    /// Unknown, corrupt or incomplete user packages yield an explicit safe
    /// Original fallback. The existing program(for:) API is never changed.
    static func resolvePackage(id: String,
                               from store: CreativePresetPackageStore) async
        -> CreativePresetPackageSelection? {
        if let builtIn = builtInPackage(for: id) {
            return CreativePresetPackageSelection(
                package: builtIn, usedFallback: false)
        }
        if let user = await store.load(id: id) {
            return CreativePresetPackageSelection(
                package: user, usedFallback: false)
        }
        guard let original = builtInPackage(for: defaultID) else { return nil }
        return CreativePresetPackageSelection(
            package: original, usedFallback: true)
    }
}


// MARK: - Stage 9 creative experiences (data-only, opt-in)

extension CreativePresetCatalog {
    private static func authoredExperience(
        id: String, name: String, description: String,
        sourceID: String, typography: TypographyPreset,
        seed: UInt64, mapping: CreativeAudioMapping
    ) -> CreativeExperiencePreset? {
        let source = program(for: sourceID)
        let original = source.preset
        // Reuse the exact existing visual program rules and shader vocabulary.
        let renamed = CreativePreset(
            id: id, name: name, theme: original.theme,
            typographyStyle: typography.style,
            visualStyle: original.visualStyle,
            audioReaction: original.audioReaction)
        let program = CreativeVisualProgram(
            preset: renamed, rules: source.rules)
        guard let timeline = try? CompositionTimeline(
            sourceStart: 0, playbackSpeed: 1, duration: 15),
              let composition = try? CreativeSnapshotAdapter.wrap(
                program, timeline: timeline,
                deterministicSeed: seed),
              let package = try? CreativePresetPackage(
                id: id, name: name, author: "NightcoreLab",
                composition: composition, typographyPreset: typography,
                previewMetadata: CreativePresetPreviewMetadata(
                    description: description, previewElapsed: 2)) else {
            return nil
        }
        return try? CreativeExperiencePreset(
            package: package, description: description,
            audioMapping: mapping, exportStyle: .portrait)
    }

    /// These presets are complete DATA recipes but never auto-select
    /// themselves or change the current player, renderer or Story exporter.
    static let experiencePresets: [CreativeExperiencePreset] = {
        let cyber = authoredExperience(
            id: "cyber-night", name: "Cyber Night",
            description: "Chrome-inspired night drive with deterministic glitch lyrics",
            sourceID: "night-drive",
            typography: TypographyPreset(
                style: .glitch, effectIntensity: 0.7,
                deterministicSeed: 0xC1B3),
            seed: 0xC1B3,
            mapping: CreativeAudioMapping(enabled: true, bindings: [
                CreativeExperienceAudioBinding(
                    signal: .bass, target: .visualIntensity, gain: 0.3),
                CreativeExperienceAudioBinding(
                    signal: .beat, target: .typographyIntensity, gain: 0.2),
                CreativeExperienceAudioBinding(
                    signal: .frequency, target: .movement, gain: 0.12)
            ]))
        let liquid = authoredExperience(
            id: "liquid-dream", name: "Liquid Dream",
            description: "Soft Marble motion with restrained Magazine Cutout",
            sourceID: "soft-flow",
            typography: TypographyPreset(
                style: .magazineCutout, effectIntensity: 0.3,
                deterministicSeed: 0xD123),
            seed: 0xD123,
            mapping: CreativeAudioMapping(enabled: true, bindings: [
                CreativeExperienceAudioBinding(
                    signal: .energy, target: .movement, gain: 0.2),
                CreativeExperienceAudioBinding(
                    signal: .bass, target: .visualIntensity, gain: 0.15)
            ]))
        let neon = authoredExperience(
            id: "neon-pulse", name: "Neon Pulse",
            description: "Bass Pulse program with kinetic word entrances",
            sourceID: "bass-pulse",
            typography: TypographyPreset(
                style: .kinetic, audioReaction: .responsive,
                effectIntensity: 0.55, deterministicSeed: 0xB455),
            seed: 0xB455,
            mapping: CreativeAudioMapping(enabled: true, bindings: [
                CreativeExperienceAudioBinding(
                    signal: .beat, target: .typographyIntensity, gain: 0.35),
                CreativeExperienceAudioBinding(
                    signal: .energy, target: .visualIntensity, gain: 0.25),
                CreativeExperienceAudioBinding(
                    signal: .bass, target: .movement, gain: 0.3)
            ]))
        return [cyber, liquid, neon].compactMap { $0 }
    }()

    /// Look up demo experiences, then wrap the original four recipes losslessly.
    /// Unknown IDs do NOT silently overwrite current selections.
    static func experience(for id: String) -> CreativeExperiencePreset? {
        experiencePresets.first(where: { $0.id == id }) ??
            CreativeExperiencePreset.fromLegacy(id)
    }

    /// The Stage 7 user catalog is reused, not replaced. Reserve the curated
    /// demo identities in the visible result even if an old local file used
    /// the same ID; loading from disk never auto-activates an experience.
    static func availableExperiences(
        from store: CreativePresetPackageStore) async -> [CreativeExperiencePreset] {
        let originals = all.compactMap {
            CreativeExperiencePreset.fromLegacy($0.id)
        }
        let reserved = Set(originals.map(\.id) +
                           experiencePresets.map(\.id))
        let user = await store.userPackages()
        let authored = user.filter { !reserved.contains($0.id) }.compactMap {
            try? CreativeExperiencePreset(package: $0)
        }
        return originals + experiencePresets + authored
    }
}


// MARK: - Stage 12.5: one selection for recipes and complete experiences

extension CreativePresetCatalog {
    /// Complete experiences offered next to the four recipes. They share the
    /// existing `creativePresetID` preference: there is no second preset system.
    static var selectableExperiences: [CreativeExperiencePreset] { experiencePresets }

    /// The curated experience behind a selection id; nil for recipes and
    /// unknown ids (which keep resolving to Original through program(for:)).
    static func selectedExperience(id: String) -> CreativeExperiencePreset? {
        experiencePresets.first(where: { $0.id == id })
    }

    /// The program behind any selectable id: the experience's own program,
    /// otherwise the recipe (unknown ids fall back to Original as before).
    static func recipe(for id: String) -> CreativeVisualProgram {
        selectedExperience(id: id)?.composition.program ?? program(for: id)
    }

    /// Choosing an experience is an explicit request for its typography
    /// effect, so it becomes the karaoke preference. Recipes, theme and font
    /// are left untouched (a selection never changes the AppTheme).
    static func typographyStyle(afterSelecting id: String,
                                current: TypographyStyle) -> TypographyStyle {
        selectedExperience(id: id)?.typographyPreset.style ?? current
    }

    /// The ONE typography preset for the live karaoke and the Story request.
    /// While the selected experience's style is active, its authored
    /// intensity, seed and mapping apply; its audio reaction only while the
    /// visuals react (`reacts`). Any other combination is the plain
    /// `TypographyPreset.current`, i.e. exactly the pre-12.5 behavior.
    static func typographyPreset(selection id: String, style: TypographyStyle,
                                 font: TypographyFont, reacts: Bool) -> TypographyPreset {
        guard let authored = selectedExperience(id: id)?.typographyPreset,
              authored.style == style else {
            return .current(style: style, font: font)
        }
        return TypographyPreset(
            style: authored.style,
            audioReaction: reacts ? authored.audioReaction : .off,
            effectIntensity: authored.effectIntensity,
            audioMapping: authored.audioMapping,
            deterministicSeed: authored.deterministicSeed,
            font: font)
    }

    /// The experience-level audio envelope applied to typography, under the
    /// same conditions as `typographyPreset(selection:style:font:reacts:)`.
    static func typographyAudioMapping(selection id: String, style: TypographyStyle,
                                       reacts: Bool) -> CreativeAudioMapping {
        guard reacts, let experience = selectedExperience(id: id),
              experience.typographyPreset.style == style else { return .disabled }
        return experience.audioMapping
    }
}
