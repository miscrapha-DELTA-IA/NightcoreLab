import AVFoundation
import Foundation

/// The index lives alongside the audio in Caches. Missing/evicted files are never cache hits.
struct TrackAudioCache {
    struct Entry: Codable {
        var track: Track
        let relativePath: String
        var accessedAt: Date
    }
    let folder: URL
    private(set) var entries: [String: Entry] = [:]

    init(folder: URL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("NightcoreAudio", isDirectory: true)) {
        self.folder = folder
        if let data = try? Data(contentsOf: folder.appendingPathComponent("index.json")),
           let index = try? JSONDecoder().decode([String: Entry].self, from: data) {
            entries = index.filter { _, entry in
                FileManager.default.fileExists(atPath: folder.appendingPathComponent(entry.relativePath).path)
            }
        }
    }

    mutating func localURL(for id: String) -> URL? {
        guard let entry = entries[id] else { return nil }
        let url = folder.appendingPathComponent(entry.relativePath)
        guard FileManager.default.fileExists(atPath: url.path) else {
            entries[id] = nil
            return nil
        }
        entries[id]?.accessedAt = Date()
        return url
    }

    mutating func store(_ track: Track, from temporaryURL: URL) throws -> URL {
        // Opening the container rejects empty files and HTML/JSON error bodies served with HTTP 200.
        let audio = try AVAudioFile(forReading: temporaryURL)
        guard audio.length > 0, audio.processingFormat.sampleRate > 0,
              (1...2).contains(audio.processingFormat.channelCount) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let directory = folder.appendingPathComponent(track.id, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let safeTitle = track.title.components(separatedBy: CharacterSet(charactersIn: "/\\:\n\r"))
            .joined(separator: " ").prefix(100)
        let relative = "\(track.id)/\(safeTitle.isEmpty ? track.id : String(safeTitle)).m4a"
        let destination = folder.appendingPathComponent(relative)
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.moveItem(at: temporaryURL, to: destination)
        var cached = track
        cached.isCached = true
        entries[track.id] = Entry(track: cached, relativePath: relative, accessedAt: Date())
        try persist()
        return destination
    }

    mutating func trim(protecting ids: Set<String>) {
        // Keep at most 30 tracks / 512 MB, without evicting the playing track or current queue.
        let sizes = entries.mapValues { entry -> Int in
            let values = try? folder.appendingPathComponent(entry.relativePath).resourceValues(forKeys: [.fileSizeKey])
            return values?.fileSize ?? 0
        }
        var bytes = sizes.values.reduce(0, +)
        for (id, entry) in entries.sorted(by: { $0.value.accessedAt < $1.value.accessedAt }) {
            guard entries.count > 30 || bytes > 512 * 1024 * 1024 else { break }
            guard !ids.contains(id) else { continue }
            try? FileManager.default.removeItem(at: folder.appendingPathComponent(entry.relativePath).deletingLastPathComponent())
            entries[id] = nil
            bytes -= sizes[id] ?? 0
        }
        try? persist()
    }

    private func persist() throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try JSONEncoder().encode(entries).write(to: folder.appendingPathComponent("index.json"), options: .atomic)
    }
}
