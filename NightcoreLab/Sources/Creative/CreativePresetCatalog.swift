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
        seed: UInt64, material: VisualMaterial, mapping: CreativeAudioMapping
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
            audioMapping: mapping, exportStyle: .portrait, material: material)
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
            seed: 0xC1B3, material: VisualMaterialCatalog.cyberChrome,
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
            description: "Procedural liquid glass with restrained Magazine Cutout",
            sourceID: "soft-flow",
            typography: TypographyPreset(
                style: .magazineCutout, effectIntensity: 0.3,
                deterministicSeed: 0xD123),
            seed: 0xD123, material: VisualMaterialCatalog.glassSurface,
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
            seed: 0xB455, material: VisualMaterialCatalog.neonPulse,
            mapping: CreativeAudioMapping(enabled: true, bindings: [
                CreativeExperienceAudioBinding(
                    signal: .beat, target: .typographyIntensity, gain: 0.35),
                CreativeExperienceAudioBinding(
                    signal: .energy, target: .visualIntensity, gain: 0.25),
                CreativeExperienceAudioBinding(
                    signal: .bass, target: .movement, gain: 0.3)
            ]))
        let chrome = authoredExperience(
            id: "chrome-night", name: "Chrome Night",
            description: "Metallic reflection bands and accent highlights",
            sourceID: "night-drive",
            typography: TypographyPreset(style: .neon, effectIntensity: 0.5),
            seed: 0xC400, material: VisualMaterialCatalog.chromeNight,
            mapping: CreativeAudioMapping(enabled: true, bindings: [
                .init(signal: .energy, target: .visualIntensity, gain: 0.2)
            ]))
        let organic = authoredExperience(
            id: "organic-pulse", name: "Organic Pulse",
            description: "Bass-reactive spatial fractal turbulence",
            sourceID: "bass-pulse",
            typography: TypographyPreset(style: .kinetic, effectIntensity: 0.55),
            seed: 0x0A61, material: VisualMaterialCatalog.organicPulse,
            mapping: CreativeAudioMapping(enabled: true, bindings: [
                .init(signal: .bass, target: .movement, gain: 0.3)
            ]))
        let marble = authoredExperience(
            id: "cyber-marble", name: "Cyber Marble",
            description: "Layered high-contrast organic marble",
            sourceID: "original",
            typography: TypographyPreset(style: .glitch, effectIntensity: 0.55),
            seed: 0xC1B5, material: VisualMaterialCatalog.advancedMarble,
            mapping: CreativeAudioMapping(enabled: true, bindings: [
                .init(signal: .beat, target: .visualIntensity, gain: 0.2)
            ]))
        let smoke = authoredExperience(
            id: "atmospheric-smoke", name: "Atmospheric Smoke",
            description: "Low-density procedural smoke drifting with the track",
            sourceID: "soft-flow",
            typography: TypographyPreset(style: .magazineCutout, effectIntensity: 0.3),
            seed: 0x5A01, material: VisualMaterialCatalog.smoke,
            mapping: CreativeAudioMapping(enabled: true, bindings: [
                .init(signal: .energy, target: .movement, gain: 0.2)
            ]))
        let agate = authoredExperience(
            id: "agate-zebra", name: "Agate Zebra",
            description: "Fine white/black folds, mineral gold and slate microveins",
            sourceID: "night-drive",
            typography: TypographyPreset(style: .glitch, effectIntensity: 0.38),
            seed: 0xA6A7, material: VisualMaterialCatalog.agateZebra,
            mapping: CreativeAudioMapping(enabled: true, bindings: [
                .init(signal: .energy, target: .visualIntensity, gain: 0.11),
                .init(signal: .bass, target: .movement, gain: 0.07)
            ]))
        let void = authoredExperience(
            id: "void-gloss", name: "Void Gloss",
            description: "Deep obsidian pools and cyan-crimson glossy ribbons",
            sourceID: "night-drive",
            typography: TypographyPreset(style: .neon, effectIntensity: 0.38),
            seed: 0xB01D, material: VisualMaterialCatalog.voidGloss,
            mapping: CreativeAudioMapping(enabled: true, bindings: [
                .init(signal: .energy, target: .visualIntensity, gain: 0.11),
                .init(signal: .bass, target: .movement, gain: 0.07)
            ]))
        let terrazzo = authoredExperience(
            id: "terrazzo-magma", name: "Terrazzo Magma",
            description: "Embossed volcanic stone ribbons and mineral speckle",
            sourceID: "bass-pulse",
            typography: TypographyPreset(style: .kinetic, effectIntensity: 0.38),
            seed: 0x7E22, material: VisualMaterialCatalog.terrazzoMagma,
            mapping: CreativeAudioMapping(enabled: true, bindings: [
                .init(signal: .energy, target: .visualIntensity, gain: 0.11),
                .init(signal: .bass, target: .movement, gain: 0.07)
            ]))
        let airbrush = authoredExperience(
            id: "airbrush-mirage", name: "Airbrush Mirage",
            description: "Diffuse color clouds with subtle ridged scanlines",
            sourceID: "soft-flow",
            typography: TypographyPreset(style: .magazineCutout, effectIntensity: 0.38),
            seed: 0xA18B, material: VisualMaterialCatalog.airbrushMirage,
            mapping: CreativeAudioMapping(enabled: true, bindings: [
                .init(signal: .energy, target: .visualIntensity, gain: 0.11),
                .init(signal: .bass, target: .movement, gain: 0.07)
            ]))
        let ebru = authoredExperience(
            id: "groove-ebru", name: "Groove Ebru",
            description: "Warm 1970s laminar liquid comb patterns",
            sourceID: "soft-flow",
            typography: TypographyPreset(style: .kinetic, effectIntensity: 0.38),
            seed: 0xE8B0, material: VisualMaterialCatalog.grooveEbru,
            mapping: CreativeAudioMapping(enabled: true, bindings: [
                .init(signal: .energy, target: .visualIntensity, gain: 0.11),
                .init(signal: .bass, target: .movement, gain: 0.07)
            ]))
        let cymatic = authoredExperience(
            id: "cymatic-rorschach", name: "Cymatic Rorschach",
            description: "Bilateral engraved wave interference with halftone light",
            sourceID: "night-drive",
            typography: TypographyPreset(style: .minimal, effectIntensity: 0.38),
            seed: 0xC7A1, material: VisualMaterialCatalog.cymaticRorschach,
            mapping: CreativeAudioMapping(enabled: true, bindings: [
                .init(signal: .energy, target: .visualIntensity, gain: 0.11),
                .init(signal: .bass, target: .movement, gain: 0.07)
            ]))
        let creativeUniverse = CreativeUniverseCatalog.experiences.compactMap { entry in
            authoredExperience(
                id: "gnarly-exp-" + entry.slug, name: entry.name,
                description: "Gnarly Creative Universe · " + entry.references,
                sourceID: entry.id == 10 ? "night-drive" :
                    (entry.id == 11 || entry.id == 12 ? "soft-flow" : "bass-pulse"),
                typography: TypographyPreset(
                    style: entry.id == 7 || entry.id == 12 ? .magazineCutout :
                           (entry.id == 10 ? .kinetic : .minimal),
                    effectIntensity: 0.38, deterministicSeed: UInt64(entry.id) * 0x1157),
                seed: UInt64(entry.id) * 0x1157,
                material: CreativeUniverseCatalog.material(for: entry),
                mapping: CreativeAudioMapping(enabled: true, bindings: [
                    .init(signal: .bass, target: .visualIntensity, gain: 0.20),
                    .init(signal: .energy, target: .movement, gain: 0.12)
                ]))
        }
        return ([cyber, liquid, neon, chrome, organic, marble, smoke,
                agate, void, terrazzo, airbrush, ebru, cymatic].compactMap { $0 }) + creativeUniverse
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
        return originals + selectableExperiences + authored
    }
}


// MARK: - Stage 12.5: one selection for recipes and complete experiences

extension CreativePresetCatalog {
    /// The seven iPhone-validated experiences are the ONLY built-in choices.
    /// Retain archived models for decoding previously exported presets and
    /// preserving Stage 13/EXP-7 material test and export contracts.
    static let liveExperienceIDs: [String] = [
        "cyber-night", "liquid-dream", "neon-pulse", "chrome-night",
        "organic-pulse", "cyber-marble", "atmospheric-smoke"
    ] + CreativeUniverseCatalog.experiences.map { "gnarly-exp-" + $0.slug }
    static var selectableExperiences: [CreativeExperiencePreset] {
        liveExperienceIDs.compactMap { id in experiencePresets.first { $0.id == id } }
    }
    static func isLiveExperience(_ id: String) -> Bool {
        liveExperienceIDs.contains(id)
    }
    /// Only migrate now-hidden curated entries. Saved user-created packages
    /// stay in storage and legacy lookups remain backwards compatible.
    static func liveSelection(_ id: String) -> String {
        experiencePresets.contains(where: { $0.id == id }) && !isLiveExperience(id)
            ? liveExperienceIDs[0] : id
    }

    /// The curated experience behind a selection id; nil for recipes and
    /// unknown ids (which keep resolving to Original through program(for:)).
    static func selectedExperience(id: String) -> CreativeExperiencePreset? {
        experiencePresets.first(where: { $0.id == id })
    }

    /// The material for any selectable id, through the single material rule
    /// (CreativeExperienceResolver.material). Unknown ids → Original's Marble.
    static func material(selection id: String) -> VisualMaterial {
        CreativeExperienceResolver.material(experience: selectedExperience(id: id),
                                            recipe: recipe(for: id))
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
