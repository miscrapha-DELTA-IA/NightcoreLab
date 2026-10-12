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

    init(id: String, name: String, author: String,
         composition: VisualComposition,
         typographyPreset: TypographyPreset? = nil,
         previewMetadata: CreativePresetPreviewMetadata = .init()) throws {
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
        previewMetadata.isValid(for: composition)
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
        case composition, audioMapping, previewMetadata
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let version = try c.decode(Int.self, forKey: .schemaVersion)
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

        guard let built = try? Self(id: id, name: name, author: author,
                                    composition: composition,
                                    typographyPreset: typography,
                                    previewMetadata: preview),
              built.visualPreset == visual,
              built.audioMapping == mapping else {
            throw DecodingError.dataCorrupted(.init(
                codingPath: decoder.codingPath,
                debugDescription: "Inconsistent or incomplete creative preset package"))
        }
        self = built
    }
}
