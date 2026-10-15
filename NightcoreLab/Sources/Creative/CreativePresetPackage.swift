import Foundation

/// Display and export discovery metadata, NOT settings applied to Share Export.
enum CreativePresetCanvasHint: String, Codable, Sendable {
    case portrait, square, landscape
}

struct CreativePresetPreviewMetadata: Codable, Equatable, Sendable {
    let description: String
    /// Video elapsed seconds, not the original audio clock.
    let previewElapsed: TimeInterval
    let canvasHint: CreativePresetCanvasHint

    init(description: String = "", previewElapsed: TimeInterval = 0,
         canvasHint: CreativePresetCanvasHint = .portrait) {
        self.description = description
        self.previewElapsed = previewElapsed
        self.canvasHint = canvasHint
    }

    func isValid(for composition: VisualComposition) -> Bool {
        description.count <= 512 &&
        previewElapsed.isFinite && previewElapsed >= 0 &&
        previewElapsed <= composition.timeline.duration
    }
}

/// A reference/index of the EXISTING equations and bindings in composition.
/// There is intentionally no second list of equations to execute or keep synced.
struct CreativePresetAudioMapping: Codable, Equatable, Sendable {
    enum Source: String, Codable, Sendable {
        case embeddedComposition
    }

    let source: Source
    let signals: [CreativeSignal]
    let hasProgramRules: Bool
    let hasLayerBindings: Bool

    static func referencing(_ composition: VisualComposition) -> Self {
        let program = composition.program.rules
        let bindings = composition.layers.flatMap(\.bindings)
        let signals = Set(program.map(\.equation.signal) +
                          bindings.map(\.equation.signal))
            .sorted { $0.rawValue < $1.rawValue }
        return Self(source: .embeddedComposition,
                    signals: signals,
                    hasProgramRules: !program.isEmpty,
                    hasLayerBindings: !bindings.isEmpty)
    }
}


// MARK: - Stage 19A.1: additive, song-scoped creative manifest

/// The harmonic information is advisory for the current original drum kit.
/// Its 808 is a fixed synthesized sample, NOT automatically key-tuned.
struct SongPadGuardrails: Codable, Equatable, Sendable {
    let bpm: Double?
    let tonic: MusicalPitchClass?
    let scale: MusicalScale?
    let subdivision: Int
    let melodicPadTuningActive: Bool

    var isValid: Bool {
        (bpm == nil || (bpm!.isFinite && (55...210).contains(bpm!))) &&
        (subdivision == 1 || subdivision == 2 || subdivision == 4) &&
        (tonic == nil || scale != nil) &&
        !melodicPadTuningActive // No tuned melodic kit exists in Stage 19A.1.
    }
}

/// References existing catalog presets, CreatorControls, and PadKit; never
/// duplicates visual equations, PCM, tracks, or a playback timeline.
struct SongCreativeProfile: Codable, Equatable, Sendable {
    static let schemaVersion = 1

    let version: Int
    let assetID: String
    let sourceRevision: String
    let visualPresetID: String
    let materialID: String
    let typographyPreset: TypographyPreset
    let padKitID: String
    let padMapping: SongPadGuardrails
    /// 0...1; mapped to the existing reverb wet/dry parameter on explicit apply.
    /// No vocal isolation or independent vocal track is implied.
    let vocalAndAudioFXMacro: Double
    let vocalFX: VocalFXSetting
    let reactionProfile: CreativePreset.AudioReaction

    init(assetID: String, sourceRevision: String,
         visualPresetID: String, materialID: String,
         typographyPreset: TypographyPreset, padKitID: String = PadKit.starter.id,
         padMapping: SongPadGuardrails,
         vocalAndAudioFXMacro: Double = 0,
          vocalFX: VocalFXSetting = .init(),
         reactionProfile: CreativePreset.AudioReaction = .subtle) {
        version = Self.schemaVersion
        self.assetID = assetID
        self.sourceRevision = sourceRevision
        self.visualPresetID = visualPresetID
        self.materialID = materialID
        self.typographyPreset = typographyPreset
        self.padKitID = padKitID
        self.padMapping = padMapping
        self.vocalAndAudioFXMacro = vocalAndAudioFXMacro
        self.vocalFX = vocalFX
        self.reactionProfile = reactionProfile
    }

    var isValid: Bool {
        version == Self.schemaVersion &&
        !assetID.isEmpty && assetID.count <= 256 &&
        !sourceRevision.isEmpty && sourceRevision.count <= 256 &&
        !visualPresetID.isEmpty && visualPresetID.count <= 128 &&
        !materialID.isEmpty && materialID.count <= 128 &&
        padKitID == PadKit.starter.id &&
        padMapping.isValid &&
        vocalAndAudioFXMacro.isFinite && (0...1).contains(vocalAndAudioFXMacro) &&
        vocalFX.isValid
    }

    private enum CodingKeys: String, CodingKey {
        case version, assetID, sourceRevision, visualPresetID, materialID
        case typographyPreset, padKitID, padMapping
        case vocalAndAudioFXMacro, vocalFX, reactionProfile
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let version = try c.decode(Int.self, forKey: .version)
        guard version == Self.schemaVersion else {
            throw DecodingError.dataCorruptedError(
                forKey: .version, in: c,
                debugDescription: "Unsupported song creative profile")
        }
        self.init(
            assetID: try c.decode(String.self, forKey: .assetID),
            sourceRevision: try c.decode(String.self, forKey: .sourceRevision),
            visualPresetID: try c.decode(String.self, forKey: .visualPresetID),
            materialID: try c.decode(String.self, forKey: .materialID),
            typographyPreset: try c.decode(TypographyPreset.self, forKey: .typographyPreset),
            padKitID: try c.decode(String.self, forKey: .padKitID),
            padMapping: try c.decode(SongPadGuardrails.self, forKey: .padMapping),
            vocalAndAudioFXMacro: try c.decode(Double.self, forKey: .vocalAndAudioFXMacro),
            vocalFX: try c.decodeIfPresent(VocalFXSetting.self, forKey: .vocalFX) ?? .init(),
            reactionProfile: try c.decode(CreativePreset.AudioReaction.self, forKey: .reactionProfile))
        guard isValid else {
            throw DecodingError.dataCorrupted(.init(
                codingPath: decoder.codingPath,
                debugDescription: "Invalid song creative profile"))
        }
    }
}

/// Portable, self-contained authoring envelope ABOVE the existing preset,
/// visual program, typography preset and composition. No renderer is activated.
struct CreativePresetPackage: Codable, Equatable, Sendable, Identifiable {
    static let supportedSchemaVersion = 1

    enum PackageError: Error {
        case invalidPackage
        case unsupportedSchema
    }

    let id: String
    let schemaVersion: Int
    let name: String
    let author: String
    let visualPreset: VisualPreset
    let typographyPreset: TypographyPreset
    let composition: VisualComposition
    let audioMapping: CreativePresetAudioMapping
    let previewMetadata: CreativePresetPreviewMetadata
    /// Optional v1 extension; legacy package JSON has no song-scoped field.
    let songProfile: SongCreativeProfile?

    init(id: String, name: String, author: String,
         composition: VisualComposition,
         typographyPreset: TypographyPreset? = nil,
         previewMetadata: CreativePresetPreviewMetadata = .init(),
         songProfile: SongCreativeProfile? = nil) throws {
        self.id = id
        self.schemaVersion = Self.supportedSchemaVersion
        self.name = name
        self.author = author
        self.composition = composition
        self.visualPreset = composition.program.preset.visualStyle
        self.typographyPreset = typographyPreset ??
            TypographyPreset(style: composition.program.preset.typographyStyle)
        self.audioMapping = .referencing(composition)
        self.previewMetadata = previewMetadata
        self.songProfile = songProfile
        guard isValid else { throw PackageError.invalidPackage }
    }

    var isValid: Bool {
        schemaVersion == Self.supportedSchemaVersion &&
        !id.isEmpty && id.count <= 128 &&
        !name.isEmpty && name.count <= 256 &&
        !author.isEmpty && author.count <= 128 &&
        composition.isValid &&
        id == composition.id &&
        name == composition.name &&
        visualPreset == composition.program.preset.visualStyle &&
        Self.typographyMatches(typographyPreset.style,
                               composition.program.preset.typographyStyle) &&
        audioMapping == .referencing(composition) &&
        previewMetadata.isValid(for: composition) &&
        (songProfile?.isValid ?? true)
    }

    /// The package's typography style must be the one its preset records.
    /// Packages authored before Stage 10B projected glitch/kinetic/minimal to
    /// `.neon` in the CreativePreset; that single legacy pairing still loads.
    private static func typographyMatches(_ typography: TypographyStyle,
                                          _ recorded: TypographyStyle) -> Bool {
        typography == recorded ||
            (recorded == .neon && !typography.predatesExtendedStyles)
    }

    /// Portable import of existing CreativeVisualProgram recipes, including all
    /// catalog audio rules, with neutral composition defaults and no new effects.
    static func wrap(_ program: CreativeVisualProgram, author: String,
                     timeline: CompositionTimeline,
                     layers: [PresetLayer] = PresetLayer.defaultLayers,
                     seed: UInt64 = 0) throws -> CreativePresetPackage {
        let composition = try CreativeSnapshotAdapter.wrap(
            program, timeline: timeline, layers: layers,
            deterministicSeed: seed)
        return try CreativePresetPackage(
            id: program.id, name: program.preset.name,
            author: author, composition: composition)
    }

    private enum CodingKeys: String, CodingKey {
        case id, schemaVersion, name, author, visualPreset, typographyPreset
        case composition, audioMapping, previewMetadata, songProfile
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let version = try c.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        guard version == Self.supportedSchemaVersion else {
            throw DecodingError.dataCorruptedError(
                forKey: .schemaVersion, in: c,
                debugDescription: "Unsupported creative preset package schema")
        }
        let composition = try c.decode(VisualComposition.self, forKey: .composition)
        let id = try c.decode(String.self, forKey: .id)
        let name = try c.decode(String.self, forKey: .name)
        let author = try c.decode(String.self, forKey: .author)
        // Early v1 drafts may omit derived descriptors. Reconstruct them from
        // the single authoritative composition; NEVER guess a missing program.
        let visual = try c.decodeIfPresent(VisualPreset.self, forKey: .visualPreset) ??
            composition.program.preset.visualStyle
        let typography = try c.decodeIfPresent(
            TypographyPreset.self, forKey: .typographyPreset) ??
            TypographyPreset(style: composition.program.preset.typographyStyle)
        let mapping = try c.decodeIfPresent(
            CreativePresetAudioMapping.self, forKey: .audioMapping) ??
            .referencing(composition)
        let preview = try c.decodeIfPresent(
            CreativePresetPreviewMetadata.self, forKey: .previewMetadata) ?? .init()
        let song = try c.decodeIfPresent(
            SongCreativeProfile.self, forKey: .songProfile)

        guard let built = try? Self(id: id, name: name, author: author,
                                    composition: composition,
                                    typographyPreset: typography,
                                    previewMetadata: preview,
                                    songProfile: song),
              built.visualPreset == visual,
              built.audioMapping == mapping else {
            throw DecodingError.dataCorrupted(.init(
                codingPath: decoder.codingPath,
                debugDescription: "Inconsistent or incomplete creative preset package"))
        }
        self = built
    }
}
