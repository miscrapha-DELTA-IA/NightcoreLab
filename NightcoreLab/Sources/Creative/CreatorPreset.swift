import Foundation

/// Portable, locally persisted edit recipe. No backend, user identity or MIDI.
struct CreatorPreset: Codable, Equatable, Sendable {
    static let schemaVersion = 1
    let version: Int
    var experienceID: String
    var materialID: String
    var typography: TypographyPreset
    var controls: CreatorControls
    var exportProfile: ExportProfile

    init(experienceID: String, materialID: String,
         typography: TypographyPreset, controls: CreatorControls = .neutral,
         exportProfile: ExportProfile = ExportProfile()) {
        version = Self.schemaVersion
        self.experienceID = experienceID
        self.materialID = materialID
        self.typography = typography
        self.controls = controls
        self.exportProfile = exportProfile
    }

    var isValid: Bool {
        version == Self.schemaVersion &&
        !experienceID.isEmpty && !materialID.isEmpty && controls.isValid
    }

    func applying(to request: StoryVideoRequest) -> StoryVideoRequest {
        var result = request
        result.creatorParameters = ControlMapping.resolve(controls)
        result.layoutPolicy = CompositionLayoutPolicy.resolve(
            profile: exportProfile.encodingProfile(for: request.mode),
            mode: request.mode)
        result.typographyPreset = typography

        let existing = request.renderRuntime
        let currentExperience = existing?.composition.program.id
        let selectedMaterial = VisualMaterialCatalog.all.first { $0.id == materialID } ??
            CreativePresetCatalog.material(selection: experienceID)
        if currentExperience == experienceID, let existing {
            if existing.material.id != selectedMaterial.id {
                // Material change is an editor event: recompile once, not per frame.
                result.compositionRuntime = CompositionRuntime(
                    composition: existing.composition, material: selectedMaterial)
            }
            return result
        }
        let program = CreativePresetCatalog.effectiveProgram(
            id: experienceID, theme: request.theme,
            typography: typography.style, background: request.playerStyle,
            reaction: CreativePresetCatalog.recipe(for: experienceID).preset.audioReaction)
        if let composition = CompositionRuntime.freeze(
            program: program, sourceStart: request.playbackTime,
            speed: Double(request.speed), duration: request.duration,
            deterministicSeed: CreativePresetCatalog.selectedExperience(id: experienceID)?
                .composition.deterministicSeed ?? 0) {
            result.compositionRuntime = CompositionRuntime(
                composition: composition, material: selectedMaterial)
        }
        return result
    }

    private enum CodingKeys: String, CodingKey {
        case version, experienceID, materialID, typography, controls, exportProfile
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let version = try c.decode(Int.self, forKey: .version)
        guard version == Self.schemaVersion else {
            throw DecodingError.dataCorruptedError(
                forKey: .version, in: c, debugDescription: "Unsupported creator preset schema")
        }
        self.version = version
        experienceID = try c.decode(String.self, forKey: .experienceID)
        materialID = try c.decode(String.self, forKey: .materialID)
        typography = try c.decode(TypographyPreset.self, forKey: .typography)
        controls = try c.decode(CreatorControls.self, forKey: .controls)
        exportProfile = try c.decode(ExportProfile.self, forKey: .exportProfile)
        guard isValid else {
            throw DecodingError.dataCorrupted(.init(
                codingPath: decoder.codingPath, debugDescription: "Invalid creator preset"))
        }
    }
}

/// Local-only persistence with a stable schema and a single namespaced key.
/// A caller may provide an isolated defaults suite for deterministic tests.
enum CreatorPresetStore {
    private static let key = "NightcoreLab.creatorPreset.v1"

    static func save(_ preset: CreatorPreset,
                     defaults: UserDefaults = .standard) throws {
        guard preset.isValid else { throw CreatorPresetStoreError.invalidPreset }
        defaults.set(try JSONEncoder().encode(preset), forKey: key)
    }

    static func load(defaults: UserDefaults = .standard) -> CreatorPreset? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(CreatorPreset.self, from: data)
    }
}

enum CreatorPresetStoreError: Error {
    case invalidPreset
}