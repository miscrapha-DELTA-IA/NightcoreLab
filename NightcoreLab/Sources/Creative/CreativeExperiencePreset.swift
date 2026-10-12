import Foundation

/// A VERSIONED, opt-in experience adapter ABOVE CreativePresetPackage.
/// The package is authoritative for visual, typography, composition and
/// existing typed equations. These projections are never stored twice.
struct CreativeExperiencePreset: Codable, Equatable, Sendable, Identifiable {
    static let supportedSchemaVersion = 1

    enum ExperienceError: Error {
        case invalidExperience
    }

    let schemaVersion: Int
    let package: CreativePresetPackage
    let description: String
    let audioMapping: CreativeAudioMapping
    /// Metadata only; does NOT select StoryEncodingProfile or MP4 dimensions.
    let exportStyle: CreativePresetCanvasHint

    var id: String { package.id }
    var name: String { package.name }
    var visualPreset: VisualPreset { package.visualPreset }
    var typographyPreset: TypographyPreset { package.typographyPreset }
    var composition: VisualComposition { package.composition }
    var author: String { package.author }

    init(package: CreativePresetPackage,
         description: String = "",
         audioMapping: CreativeAudioMapping = .disabled,
         exportStyle: CreativePresetCanvasHint = .portrait) throws {
        self.schemaVersion = Self.supportedSchemaVersion
        self.package = package
        self.description = description
        self.audioMapping = audioMapping
        self.exportStyle = exportStyle
        guard isValid else { throw ExperienceError.invalidExperience }
    }

    var isValid: Bool {
        schemaVersion == Self.supportedSchemaVersion &&
        package.isValid && description.count <= 512 &&
        audioMapping.isValid
    }

    /// Legacy conversion is lossless: complete CreativeVisualProgram,
    /// rules, keyframes and deterministicSeed are preserved.
    static func fromLegacy(_ id: String) -> CreativeExperiencePreset? {
        guard let package = CreativePresetCatalog.builtInPackage(for: id) else {
            return nil
        }
        return try? Self(
            package: package, description: "Preset original NightcoreLab")
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, package, description, audioMapping, exportStyle
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let schema = try c.decode(Int.self, forKey: .schemaVersion)
        guard schema == Self.supportedSchemaVersion else {
            throw DecodingError.dataCorruptedError(
                forKey: .schemaVersion, in: c,
                debugDescription: "Unsupported experience schema")
        }
        do {
            try self.init(
                package: c.decode(CreativePresetPackage.self, forKey: .package),
                description: c.decode(String.self, forKey: .description),
                audioMapping: c.decode(CreativeAudioMapping.self, forKey: .audioMapping),
                exportStyle: c.decode(CreativePresetCanvasHint.self,
                                      forKey: .exportStyle))
        } catch let error as DecodingError {
            throw error
        } catch {
            throw DecodingError.dataCorrupted(.init(
                codingPath: decoder.codingPath,
                debugDescription: "Invalid creative experience"))
        }
    }
}
