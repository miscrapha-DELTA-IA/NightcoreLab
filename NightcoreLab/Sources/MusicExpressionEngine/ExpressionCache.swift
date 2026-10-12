import Foundation

/// Separate, disposable cache for Stage 3A. Each expression capability has an
/// independent, atomic JSON entry; changes never touch MusicAnalysisCache.
actor ExpressionCache {
    static let defaultDirectory = FileManager.default.urls(
        for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("MusicExpression", isDirectory: true)

    enum CacheError: Error {
        case invalidResult
        case entryExceedsBudget
    }

    private struct Entry: Codable, Sendable {
        let schemaVersion: Int
        let assetID: String
        let sourceRevision: String
        let sourceDuration: TimeInterval
        let capability: ExpressionCapability
        let payload: ExpressionPayload

        func isValid(for asset: AudioAssetDescriptor,
                     capability requested: ExpressionCapability) -> Bool {
            schemaVersion == MusicExpressionResult.currentSchemaVersion &&
            assetID == asset.assetID && sourceRevision == asset.sourceRevision &&
            sourceDuration == asset.duration && capability == requested &&
            payload.capability == requested &&
            payload.isValid(sourceDuration: asset.duration)
        }
    }

    private let directory: URL
    private let maxBytes: Int

    init(directory: URL = ExpressionCache.defaultDirectory,
         maxBytes: Int = 32 * 1_024 * 1_024) {
        self.directory = directory
        self.maxBytes = max(0, maxBytes)
    }

    /// A request declares EXACTLY which algorithm/dependency versions it can
    /// accept. All others stay notRequested. Cache does not run any analyzer.
    func load(for asset: AudioAssetDescriptor,
              requiring versions: [ExpressionCapability: ExpressionFingerprint])
        -> MusicExpressionResult {
        var statuses: [ExpressionCapability: ExpressionCapabilityStatus] = [:]
        var key: KeyAnalysisResult?
        var sections: SectionAnalysisResult?
        var melody: MelodicFeatures?
        var mood: MoodHintsResult?

        for (capability, expected) in versions where expected.isValid {
            guard let entry = readEntry(for: asset, capability: capability),
                  entry.payload.provenance.fingerprint == expected else { continue }

            // The type is checked independently of the outer entry capability.
            switch entry.payload {
            case .key(let result): key = result
            case .sections(let result): sections = result
            case .melody(let result): melody = result
            case .moodHints(let result): mood = result
            }
            statuses[capability] = .available
        }
        return MusicExpressionResult(asset: asset, statuses: statuses,
                                     key: key, sections: sections,
                                     melodicFeatures: melody, moodHints: mood)
    }

    /// Persist any valid AVAILABLE capability, including from a partial
    /// snapshot. Pending/notRequested/failed do not delete earlier valid
    /// entries or get persisted as permanent failures.
    func store(_ result: MusicExpressionResult, for asset: AudioAssetDescriptor) throws {
        guard result.isValid(for: asset) else { throw CacheError.invalidResult }
        let payloads: [ExpressionPayload?] = [
            result.key.map { .key($0) },
            result.sections.map { .sections($0) },
            result.melodicFeatures.map { .melody($0) },
            result.moodHints.map { .moodHints($0) }
        ]
        for payload in payloads.compactMap({ $0 }) {
            let entry = Entry(schemaVersion: MusicExpressionResult.currentSchemaVersion,
                              assetID: asset.assetID,
                              sourceRevision: asset.sourceRevision,
                              sourceDuration: asset.duration,
                              capability: payload.capability,
                              payload: payload)
            let data = try JSONEncoder().encode(entry)
            guard data.count <= maxBytes else { throw CacheError.entryExceedsBudget }
            try FileManager.default.createDirectory(at: directory,
                                                    withIntermediateDirectories: true)
            try data.write(to: fileURL(for: asset, capability: payload.capability),
                           options: .atomic)
        }
        trim()
    }

    /// Invalidate only named expression entries. Energy and rhythm are outside
    /// this directory and cannot be deleted through this API.
    func invalidate(_ capabilities: Set<ExpressionCapability>,
                    for asset: AudioAssetDescriptor) {
        for capability in capabilities {
            try? FileManager.default.removeItem(at: fileURL(for: asset, capability: capability))
        }
    }

    private func readEntry(for asset: AudioAssetDescriptor,
                           capability: ExpressionCapability) -> Entry? {
        let url = fileURL(for: asset, capability: capability)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        do {
            let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard size > 0, size <= maxBytes else {
                try? FileManager.default.removeItem(at: url)
                return nil
            }
            let entry = try JSONDecoder().decode(Entry.self, from: Data(contentsOf: url))
            guard entry.isValid(for: asset, capability: capability) else {
                try? FileManager.default.removeItem(at: url)
                return nil
            }
            try? FileManager.default.setAttributes([.modificationDate: Date()],
                                                   ofItemAtPath: url.path)
            return entry
        } catch {
            try? FileManager.default.removeItem(at: url)
            return nil
        }
    }

    private func fileURL(for asset: AudioAssetDescriptor,
                         capability: ExpressionCapability) -> URL {
        let hashedID = AudioAssetDescriptor.digest(Data(asset.assetID.utf8))
        return directory.appendingPathComponent(hashedID + "-" + capability.rawValue)
            .appendingPathExtension("json")
    }

    private func trim() {
        let keys: Set<URLResourceKey> = [.fileSizeKey, .contentModificationDateKey]
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: Array(keys)) else { return }
        let entries = files.filter { $0.pathExtension == "json" }
            .compactMap { file -> (url: URL, size: Int, lastAccess: Date)? in
                guard let values = try? file.resourceValues(forKeys: keys) else { return nil }
                return (file, values.fileSize ?? 0,
                        values.contentModificationDate ?? .distantPast)
            }.sorted { $0.lastAccess < $1.lastAccess }
        var used = entries.reduce(0) { $0 + $1.size }
        for entry in entries where used > maxBytes {
            if (try? FileManager.default.removeItem(at: entry.url)) != nil {
                used -= entry.size
            }
        }
    }
}
