import Foundation

/// Disposable, versioned disk cache; no audio or player objects are retained.
/// Its actor serializes I/O away from the main actor. Scheduling/deduplication
/// belongs to AnalysisScheduler, not to filesystem existence checks.
actor MusicAnalysisCache {
    static let defaultDirectory = FileManager.default.urls(
        for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("MusicAnalysis", isDirectory: true)

    private let directory: URL
    private let maxBytes: Int

    init(directory: URL = MusicAnalysisCache.defaultDirectory,
         maxBytes: Int = 64 * 1_024 * 1_024) {
        self.directory = directory
        self.maxBytes = max(0, maxBytes)
    }

    func load(for asset: AudioAssetDescriptor) -> MusicAnalysisResult? {
        let url = fileURL(for: asset)
        do {
            let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard size > 0, size <= maxBytes else { return nil }
            let result = try JSONDecoder().decode(MusicAnalysisResult.self,
                                                  from: Data(contentsOf: url))
            guard result.isTerminal, result.isValid(for: asset) else {
                try? FileManager.default.removeItem(at: url)
                return nil
            }
            try? FileManager.default.setAttributes([.modificationDate: Date()],
                                                   ofItemAtPath: url.path)
            // Rhythm has its OWN version: keep energy/onsets and discard only
            // stale rhythm derivatives. Legacy v1 cache entries decode too.
            return result.rhythmAnalyzerVersion == RhythmAnalysisResult.algorithmVersion
                ? result : result.droppingRhythm()
        } catch {
            // Interrupted writes, corruption, eviction and unknown schemas are misses.
            try? FileManager.default.removeItem(at: url)
            return nil
        }
    }

    func hasOfflineSongDNA(for url: URL) async -> Bool {
        guard let asset = try? AudioAssetDescriptor.read(at: url),
              let result = load(for: asset) else { return false }
        return result.energyTimeline != nil && result.rhythmAnalysis != nil
    }

    func store(_ result: MusicAnalysisResult, for asset: AudioAssetDescriptor) throws {
        guard result.isTerminal, result.isValid(for: asset),
              result.energyTimeline != nil else { return }
        let data = try JSONEncoder().encode(result)
        guard data.count <= maxBytes else { return }
        try FileManager.default.createDirectory(at: directory,
                                                withIntermediateDirectories: true)
        // One slot per locator: a new revision replaces the old one atomically.
        try data.write(to: fileURL(for: asset), options: .atomic)
        trim()
    }

    private func fileURL(for asset: AudioAssetDescriptor) -> URL {
        // Hash again so even a manually constructed descriptor cannot escape the cache.
        directory.appendingPathComponent(AudioAssetDescriptor.digest(Data(asset.assetID.utf8)))
            .appendingPathExtension("json")
    }

    private func trim() {
        let keys: Set<URLResourceKey> = [.fileSizeKey, .contentModificationDateKey]
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: Array(keys)) else { return }
        let entries = urls.filter { $0.pathExtension == "json" }.compactMap { url -> (URL, Int, Date)? in
            guard let values = try? url.resourceValues(forKeys: keys) else { return nil }
            return (url, values.fileSize ?? 0, values.contentModificationDate ?? .distantPast)
        }.sorted { $0.2 < $1.2 }
        var total = entries.reduce(0) { $0 + $1.1 }
        for (url, size, _) in entries where total > maxBytes {
            if (try? FileManager.default.removeItem(at: url)) != nil { total -= size }
        }
    }
}
