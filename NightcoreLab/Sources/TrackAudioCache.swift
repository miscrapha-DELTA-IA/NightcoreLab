import AVFoundation
import Foundation

/// The index lives alongside the audio in Caches. Missing/evicted files are never cache hits.
struct TrackAudioCache {
    static let maxCachedTracks = 20
    static let maxDiskBytes: Int64 = 100 * 1024 * 1024
    static let aacBitRate = 144_000
    static var stemCacheFolder: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("NightcoreAudio", isDirectory: true)
    }
    static func stemDirectory(for source: URL) -> URL {
        let root = stemCacheFolder.standardizedFileURL.path + "/"
        let parent = source.deletingLastPathComponent().standardizedFileURL
        return parent.path.hasPrefix(root) ? parent : stemCacheFolder
    }
    struct Entry: Codable {
        var track: Track
        let relativePath: String
        var accessedAt: Date
        var diskBytes: Int64? = nil
    }
    let folder: URL
    private(set) var entries: [String: Entry] = [:]
    private(set) var pinnedIDs = Set<String>()

    var totalDiskBytes: Int64 {
        entries.values.reduce(0) { $0 + ($1.diskBytes ?? 0) }
    }

    var cacheBadge: String {
        "Offline (\(entries.count)/\(Self.maxCachedTracks) • ~\(totalDiskBytes / 1_000_000) MB)"
    }

    /// Always decode and re-encode the actual source format. Renaming a WAV
    /// response to .m4a is not a valid audio cache conversion.
    static func transcodeAAC(from source: URL) throws -> URL {
        let input = try AVAudioFile(forReading: source, commonFormat: .pcmFormatFloat32,
                                    interleaved: false)
        let format = input.processingFormat
        guard input.length > 0, format.sampleRate > 0,
              (1...2).contains(format.channelCount) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".m4a")
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: format.sampleRate,
            AVNumberOfChannelsKey: Int(format.channelCount),
            AVEncoderBitRateKey: aacBitRate
        ]
        do {
            let writer = try AVAudioFile(forWriting: destination, settings: settings,
                                         commonFormat: .pcmFormatFloat32,
                                         interleaved: false)
            guard let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 8192) else {
                throw CocoaError(.fileReadCorruptFile)
            }
            while true {
                try Task.checkCancellation()
                try input.read(into: pcm)
                guard pcm.frameLength > 0 else { break }
                try writer.write(from: pcm)
            }
            return destination
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
    }


    init(loadIndex: Bool = true, folder: URL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("NightcoreAudio", isDirectory: true)) {
        self.folder = folder
        guard loadIndex else { return }
        if let data = try? Data(contentsOf: folder.appendingPathComponent("offline-pins.json")),
           let pins = try? JSONDecoder().decode(Set<String>.self, from: data) {
            pinnedIDs = pins
        }
        if let data = try? Data(contentsOf: folder.appendingPathComponent("index.json")),
           let index = try? JSONDecoder().decode([String: Entry].self, from: data) {
            entries = index.filter { _, entry in
                FileManager.default.fileExists(atPath: folder.appendingPathComponent(entry.relativePath).path)
            }
        }
    }

    mutating func pin(_ id: String) {
        pinnedIDs.insert(id)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(pinnedIDs) {
            try? data.write(to: folder.appendingPathComponent("offline-pins.json"), options: .atomic)
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
        let ext = try Self.nativeExtension(for: temporaryURL)
        let directory = folder.appendingPathComponent(track.id, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let safeTitle = track.title.components(separatedBy: CharacterSet(charactersIn: "/\\:\n\r"))
            .joined(separator: " ").prefix(100)
        let relative = "\(track.id)/\(safeTitle.isEmpty ? track.id : String(safeTitle)).\(ext)"
        let destination = folder.appendingPathComponent(relative)
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.moveItem(at: temporaryURL, to: destination)
        var cached = track
        cached.isCached = true
        let bytes = (try? destination.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        entries[track.id] = Entry(track: cached, relativePath: relative, accessedAt: Date(), diskBytes: Int64(bytes))
        try persist()
        return destination
    }

    /// Inspect only the header. Decoding or re-encoding must never gate a download.
    static func nativeExtension(for source: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: source)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: 64) ?? Data()
        let bytes = Array(data)
        guard bytes.count >= 12 else { throw CocoaError(.fileReadCorruptFile) }
        let magic = String(decoding: bytes.prefix(4), as: UTF8.self)
        if magic == "RIFF" { return "wav" }
        if magic == "caff" { return "caf" }
        if String(decoding: bytes[4..<8], as: UTF8.self) == "ftyp" { return "m4a" }
        if String(decoding: bytes.prefix(3), as: UTF8.self) == "ID3" ||
            (bytes[0] == 0xff && bytes[1] & 0xe0 == 0xe0) { return "mp3" }
        throw CocoaError(.fileReadCorruptFile)
    }

    func indexedURL(for id: String) -> URL? {
        entries[id].map { folder.appendingPathComponent($0.relativePath) }
    }

    mutating func remove(_ id: String) throws {
        if let entry = entries[id] {
            let file = folder.appendingPathComponent(entry.relativePath)
            if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) }
        }
        entries[id] = nil
        pinnedIDs.remove(id)
        try persist()
    }

    mutating func trim(protecting ids: Set<String>) {
        // Enforce a 20-track / 100 MiB disposable quota without evicting pinned offline audio.
        let sizes = entries.mapValues { entry -> Int in
            let values = try? folder.appendingPathComponent(entry.relativePath).resourceValues(forKeys: [.fileSizeKey])
            return values?.fileSize ?? 0
        }
        var bytes = sizes.values.reduce(0, +)
        for (id, entry) in entries.sorted(by: { $0.value.accessedAt < $1.value.accessedAt }) {
            guard entries.count > Self.maxCachedTracks || Int64(bytes) > Self.maxDiskBytes else { break }
            guard !ids.contains(id), !pinnedIDs.contains(id) else { continue }
            try? FileManager.default.removeItem(at: folder.appendingPathComponent(entry.relativePath).deletingLastPathComponent())
            entries[id] = nil
            bytes -= sizes[id] ?? 0
        }
        try? persist()
    }

    /// Reclaim disposable downloaded tracks on memory pressure while retaining
    /// the playing, selected and in-flight queue members. Never touches an
    /// AVAudioPlayerNode buffer or the current song file.
    mutating func evictUnprotected(protecting ids: Set<String>) {
        for (id, entry) in entries where !ids.contains(id) && !pinnedIDs.contains(id) {
            let url = folder.appendingPathComponent(entry.relativePath)
            try? FileManager.default.removeItem(at: url)
            entries[id] = nil
        }
        try? persist()
    }

    private func persist() throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try JSONEncoder().encode(entries).write(to: folder.appendingPathComponent("index.json"), options: .atomic)
    }
}

/// All cache mutations and header inspection run on one dedicated I/O queue.
final class AudioCacheIO: @unchecked Sendable {
    private let queue = DispatchQueue(label: "nightcore.audio.cache", qos: .utility)
    private var cache: TrackAudioCache?
    func perform<T>(_ operation: @escaping (inout TrackAudioCache) throws -> T) async throws -> (T, TrackAudioCache) {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do {
                    var value = self.cache ?? TrackAudioCache()
                    let result = try operation(&value)
                    self.cache = value
                    continuation.resume(returning: (result, value))
                } catch { continuation.resume(throwing: error) }
            }
        }
    }
}
