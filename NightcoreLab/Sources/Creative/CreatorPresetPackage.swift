import Foundation

/// Stage 15B portable envelope, deliberately NOT a replacement for CreatorPreset.
/// The v1 JSON shape is flat and contains no URLs, account IDs or device data.
struct CreatorPresetPackage: Codable, Equatable, Sendable {
    static let supportedSchemaVersion = 1

    let schemaVersion: Int
    let name: String
    let author: String
    let createdAt: Date
    let preset: CreatorPreset

    init(name: String, author: String = "Anônimo",
         createdAt: Date = Date(), preset: CreatorPreset) throws {
        schemaVersion = Self.supportedSchemaVersion
        self.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        self.author = author.trimmingCharacters(in: .whitespacesAndNewlines)
        // ISO8601 serialization is second-precision: make round trips exact.
        self.createdAt = Date(timeIntervalSince1970:
            floor(createdAt.timeIntervalSince1970))
        self.preset = preset
        guard isValid else { throw CreatorPresetPackageError.invalidPackage }
    }

    var isValid: Bool {
        schemaVersion == Self.supportedSchemaVersion &&
        preset.isValid &&
        Self.validPublicLabel(name, maximum: 80) &&
        Self.validPublicLabel(author, maximum: 60) &&
        createdAt.timeIntervalSince1970.isFinite
    }

    private static func validPublicLabel(_ label: String, maximum: Int) -> Bool {
        !label.isEmpty && label.count <= maximum &&
        !label.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) &&
        !label.contains("/") && !label.contains("\\")
    }

    /// Mirror CreatorPreset's authored fields at the package root. A version
    /// belongs to the envelope; the in-memory CreatorPreset keeps Codable v1.
    private enum CodingKeys: String, CodingKey {
        case schemaVersion, name, author, createdAt
        case experienceID, materialID, typography, controls, exportProfile
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let version = try c.decode(Int.self, forKey: .schemaVersion)
        guard version == Self.supportedSchemaVersion else {
            throw CreatorPresetPackageError.unsupportedSchema(version)
        }
        try self.init(
            name: c.decode(String.self, forKey: .name),
            author: c.decode(String.self, forKey: .author),
            createdAt: c.decode(Date.self, forKey: .createdAt),
            preset: CreatorPreset(
                experienceID: c.decode(String.self, forKey: .experienceID),
                materialID: c.decode(String.self, forKey: .materialID),
                typography: c.decode(TypographyPreset.self, forKey: .typography),
                controls: c.decode(CreatorControls.self, forKey: .controls),
                exportProfile: c.decode(ExportProfile.self, forKey: .exportProfile)))
    }

    func encode(to encoder: Encoder) throws {
        guard isValid else { throw CreatorPresetPackageError.invalidPackage }
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(schemaVersion, forKey: .schemaVersion)
        try c.encode(name, forKey: .name)
        try c.encode(author, forKey: .author)
        try c.encode(createdAt, forKey: .createdAt)
        try c.encode(preset.experienceID, forKey: .experienceID)
        try c.encode(preset.materialID, forKey: .materialID)
        try c.encode(preset.typography, forKey: .typography)
        try c.encode(preset.controls, forKey: .controls)
        try c.encode(preset.exportProfile, forKey: .exportProfile)
    }
}

enum CreatorPresetPackageError: LocalizedError, Equatable {
    case invalidPackage
    case unsupportedSchema(Int)
    case fileTooLarge
    case unreadableFile

    var errorDescription: String? {
        switch self {
        case .invalidPackage:
            return "O preset JSON está incompleto ou contém dados inválidos."
        case .unsupportedSchema(let version):
            return "Versão \(version) do preset não suportada por este aplicativo."
        case .fileTooLarge:
            return "O arquivo de preset excede o limite de tamanho."
        case .unreadableFile:
            return "Não foi possível ler o arquivo escolhido."
        }
    }
}

enum CreatorPresetImportWarning: Equatable, Sendable {
    case experienceReplaced
    case materialReplaced
    case typographyReplaced
    case exportProfileReplaced

    var message: String {
        switch self {
        case .experienceReplaced:
            return "Experiência desconhecida: substituída por Original."
        case .materialReplaced:
            return "Material desconhecido: substituído por Original Marble."
        case .typographyReplaced:
            return "Tipografia incompatível: substituída por Neon."
        case .exportProfileReplaced:
            return "Formato ou qualidade incompatível: foi aplicado um valor seguro."
        }
    }
}

struct CreatorPresetImportResult: Identifiable, Equatable {
    let id = UUID()
    let package: CreatorPresetPackage
    let warnings: [CreatorPresetImportWarning]

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.package == rhs.package && lhs.warnings == rhs.warnings
    }
}

/// Pure v1 importer / migration dispatcher. Future versions get an explicit
/// case here, not changes to the existing CreatorPreset or a silent downgrade.
enum CreatorPresetPackageMigration {
    static func decode(_ data: Data) throws -> CreatorPresetImportResult {
        guard !data.isEmpty, data.count <= CreatorPresetSharing.maximumBytes else {
            throw CreatorPresetPackageError.fileTooLarge
        }
        guard var json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let version = json["schemaVersion"] as? Int else {
            throw CreatorPresetPackageError.invalidPackage
        }
        guard version == CreatorPresetPackage.supportedSchemaVersion else {
            throw CreatorPresetPackageError.unsupportedSchema(version)
        }
        var warnings: [CreatorPresetImportWarning] = []

        // Missing fields and invalid numeric controls are NOT silently repaired.
        // Only known vocabulary gaps may fall back to existing safe presets.
        guard let experienceID = json["experienceID"] as? String,
              let materialID = json["materialID"] as? String,
              var typography = json["typography"] as? [String: Any],
              var exportProfile = json["exportProfile"] as? [String: Any] else {
            throw CreatorPresetPackageError.invalidPackage
        }
        let experiences = Set(CreativePresetCatalog.all.map(\.id) +
                              CreativePresetCatalog.selectableExperiences.map(\.id))
        if !experiences.contains(experienceID) {
            json["experienceID"] = CreativePresetCatalog.defaultID
            warnings.append(.experienceReplaced)
        }
        if !VisualMaterialCatalog.all.contains(where: { $0.id == materialID }) {
            json["materialID"] = VisualMaterial.legacyMarble.id
            warnings.append(.materialReplaced)
        }

        let typographyDecoder = JSONDecoder()
        let typographyBytes = try JSONSerialization.data(withJSONObject: typography)
        if (try? typographyDecoder.decode(TypographyPreset.self,
                                          from: typographyBytes)) == nil {
            // Reuse a known legacy preset; no new renderer or glyph vocabulary.
            let fallback = try JSONEncoder().encode(
                TypographyPreset(style: .neon))
            guard let safe = (try JSONSerialization.jsonObject(with: fallback))
                as? [String: Any] else {
                throw CreatorPresetPackageError.invalidPackage
            }
            typography = safe
            json["typography"] = typography
            warnings.append(.typographyReplaced)
        }

        var exportFallback = false
        func ensureSupported<T: RawRepresentable>(
            _ key: String, _ allowed: T.Type, defaultValue: String
        ) where T.RawValue == String {
            if let value = exportProfile[key] as? String,
               T(rawValue: value) != nil { return }
            exportProfile[key] = defaultValue
            exportFallback = true
        }
        ensureSupported("aspectRatio", ExportAspectRatio.self, defaultValue: "portrait")
        ensureSupported("quality", ExportQuality.self, defaultValue: "balanced")
        ensureSupported("cropPolicy", ExportCropPolicy.self,
                        defaultValue: "safeAreaPreserving")
        if exportFallback {
            json["exportProfile"] = exportProfile
            warnings.append(.exportProfileReplaced)
        }

        guard JSONSerialization.isValidJSONObject(json),
              let repaired = try? JSONSerialization.data(withJSONObject: json) else {
            throw CreatorPresetPackageError.invalidPackage
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let package = try? decoder.decode(CreatorPresetPackage.self,
                                                from: repaired), package.isValid else {
            throw CreatorPresetPackageError.invalidPackage
        }
        return CreatorPresetImportResult(package: package, warnings: warnings)
    }
}

/// Local file I/O only. iOS' share sheet and Files document picker own transport.
enum CreatorPresetSharing {
    static let maximumBytes = 256 * 1_024

    static func jsonData(for package: CreatorPresetPackage) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(package)
        guard data.count <= maximumBytes else {
            throw CreatorPresetPackageError.fileTooLarge
        }
        return data
    }

    static func export(_ package: CreatorPresetPackage) throws -> URL {
        let bytes = try jsonData(for: package)
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("NightcoreCreatorPreset-\(UUID().uuidString)",
                                    isDirectory: true)
        try FileManager.default.createDirectory(
            at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent("NightcoreLab-CreatorPreset.json")
        try bytes.write(to: url, options: .atomic)
        return url
    }

    static func importFile(at url: URL) throws -> CreatorPresetImportResult {
        guard url.isFileURL else { throw CreatorPresetPackageError.unreadableFile }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              size > 0 else { throw CreatorPresetPackageError.unreadableFile }
        guard size <= maximumBytes else { throw CreatorPresetPackageError.fileTooLarge }
        guard let bytes = try? Data(contentsOf: url), bytes.count <= maximumBytes else {
            throw CreatorPresetPackageError.unreadableFile
        }
        return try CreatorPresetPackageMigration.decode(bytes)
    }
}
