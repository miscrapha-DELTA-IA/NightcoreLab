import Foundation

actor LyricsAlignmentCache {
    static let shared = LyricsAlignmentCache()
    static let schemaVersion = 2

    private struct Entry: Codable {
        let schemaVersion: Int
        let sourceKey: String
        let lines: [TimedLyricLine]

        private enum CodingKeys: String, CodingKey { case schemaVersion, sourceKey, lines }

        init(sourceKey: String, lines: [TimedLyricLine]) {
            schemaVersion = LyricsAlignmentCache.schemaVersion
            self.sourceKey = sourceKey
            self.lines = lines
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            schemaVersion = try c.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
            sourceKey = try c.decode(String.self, forKey: .sourceKey)
            lines = try c.decode([TimedLyricLine].self, forKey: .lines)
        }
    }

    private let folder: URL

    init(folder: URL = FileManager.default.urls(for: .cachesDirectory,
                                                 in: .userDomainMask)[0]
        .appendingPathComponent("NightcoreLyricsAlignment", isDirectory: true)) {
        self.folder = folder
    }

    private static func key(trackID: String, source: String) -> String {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in (trackID + "\u{0}" + source).utf8 {
            hash = (hash ^ UInt64(byte)) &* 1_099_511_628_211
        }
        return String(hash, radix: 16)
    }

    func load(trackID: String, source: String) -> [TimedLyricLine]? {
        let key = Self.key(trackID: trackID, source: source)
        let url = folder.appendingPathComponent(key).appendingPathExtension("json")
        guard let data = try? Data(contentsOf: url),
              let entry = try? JSONDecoder().decode(Entry.self, from: data),
              (1...Self.schemaVersion).contains(entry.schemaVersion),
              entry.sourceKey == key,
              entry.lines.count <= 10_000 else { return nil }
        return entry.lines
    }

    func save(_ lines: [TimedLyricLine], trackID: String, source: String) {
        guard lines.count <= 10_000 else { return }
        let key = Self.key(trackID: trackID, source: source)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(Entry(sourceKey: key, lines: lines))
            try data.write(to: folder.appendingPathComponent(key).appendingPathExtension("json"),
                           options: .atomic)
        } catch { /* Disposable cache; parsing still succeeds. */ }
    }
}
