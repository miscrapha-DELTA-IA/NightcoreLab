import Foundation

/// Application Support storage is durable across app restarts and does not
/// share folders with MusicAnalysisCache or ExpressionCache.
actor CreativePresetPackageStore {
    enum StoreError: Error {
        case reservedID
        case invalidPackage
        case packageTooLarge
    }

    static let defaultDirectory = FileManager.default.urls(
        for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("NightcoreLab/CreativePresetPackages",
                            isDirectory: true)

    private let directory: URL
    private let maximumBytes: Int

    init(directory: URL = CreativePresetPackageStore.defaultDirectory,
         maximumBytes: Int = 512 * 1_024) {
        self.directory = directory
        self.maximumBytes = max(0, maximumBytes)
    }

    /// Existing built-in names cannot be replaced by user-authored packages.
    func save(_ package: CreativePresetPackage) throws {
        guard !CreativePresetCatalog.all.contains(where: { $0.id == package.id }) else {
            throw StoreError.reservedID
        }
        guard package.isValid else { throw StoreError.invalidPackage }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(package)
        guard data.count <= maximumBytes else { throw StoreError.packageTooLarge }
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        try data.write(to: fileURL(for: package.id), options: .atomic)
    }

    /// A malformed, incomplete, mismatched-ID or unsupported-version file is a
    /// cache miss, never a reason to activate an arbitrary visual program.
    /// Unknown future schemas are preserved on disk, not deleted.
    func load(id: String) -> CreativePresetPackage? {
        guard !CreativePresetCatalog.all.contains(where: { $0.id == id }) else {
            return nil
        }
        let url = fileURL(for: id)
        guard let attributes = try? url.resourceValues(forKeys: [.fileSizeKey]),
              let length = attributes.fileSize,
              length > 0, length <= maximumBytes,
              let bytes = try? Data(contentsOf: url),
              let package = try? JSONDecoder().decode(
                CreativePresetPackage.self, from: bytes),
              package.id == id, package.isValid else { return nil }
        return package
    }

    func userPackages() -> [CreativePresetPackage] {
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil) else { return [] }
        var packages: [CreativePresetPackage] = []
        for url in urls where url.pathExtension == "json" {
            // Only hashed disk names are processed. Untrusted adjacent files
            // are never interpreted as a user preset.
            let file = url.deletingPathExtension().lastPathComponent
            guard file.count == 64,
                  file.utf8.allSatisfy({ (48...57).contains($0) ||
                                         (97...102).contains($0) }),
                  let attributes = try? url.resourceValues(forKeys: [.fileSizeKey]),
                  let length = attributes.fileSize,
                  length > 0, length <= maximumBytes,
                  let bytes = try? Data(contentsOf: url),
                  bytes.count <= maximumBytes,
                  let package = try? JSONDecoder().decode(
                    CreativePresetPackage.self, from: bytes),
                  package.isValid,
                  !CreativePresetCatalog.all.contains(where: { $0.id == package.id }),
                  fileURL(for: package.id) == url else { continue }
            packages.append(package)
        }
        return packages.sorted { $0.id < $1.id }
    }

    func delete(id: String) throws {
        guard !CreativePresetCatalog.all.contains(where: { $0.id == id }) else {
            throw StoreError.reservedID
        }
        let url = fileURL(for: id)
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }

    private func fileURL(for id: String) -> URL {
        let digest = AudioAssetDescriptor.digest(Data(id.utf8))
        return directory.appendingPathComponent(digest).appendingPathExtension("json")
    }
}

/// The caller can distinguish an exact selection from a safe built-in fallback.
struct CreativePresetPackageSelection: Equatable, Sendable {
    let package: CreativePresetPackage
    let usedFallback: Bool
}
