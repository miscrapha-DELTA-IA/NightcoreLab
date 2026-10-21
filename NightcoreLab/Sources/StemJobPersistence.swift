import CryptoKit
import Foundation

/// Backgrounding is a pause, never a user cancellation. Model checks unwind
/// the current prediction so its tensors do not remain resident while suspended.
final class StemWorkLifecycle: @unchecked Sendable {
    struct Paused: Error {}
    static let shared = StemWorkLifecycle()
    private let lock = NSLock()
    private var backgrounded = false
    func setBackgrounded(_ value: Bool) {
        lock.lock(); backgrounded = value; lock.unlock()
    }
    func check() throws {
        lock.lock(); let paused = backgrounded; lock.unlock()
        if paused { throw Paused() }
    }
    func waitForForeground() async throws {
        while true {
            try Task.checkCancellation()
            do { try check(); return } catch is Paused {
                try await Task.sleep(for: .milliseconds(250))
            }
        }
    }
}

/// One active intent, including an owned source copy. No beta code or token is
/// written here. Relaunch resumes the same source, not whatever is now playing.
struct StemJobJournal: Codable, Sendable {
    let id: UUID
    let originalSource: URL
    let source: URL
    let title: String
    let cloud: Bool
    let previewTime: Double?
    var automaticResume: Bool

    static var root: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("GnarlyStemJobs", isDirectory: true)
    }
    static func load(in root: URL = root) -> Self? {
        guard let data = try? Data(contentsOf: root.appendingPathComponent("active.json")),
              let job = try? JSONDecoder().decode(Self.self, from: data),
              job.source.isFileURL,
              job.source.deletingLastPathComponent().standardizedFileURL == root.appendingPathComponent(job.id.uuidString, isDirectory: true).standardizedFileURL,
              FileManager.default.fileExists(atPath: job.source.path) else { return nil }
        return job
    }
    static func create(source: URL, title: String, cloud: Bool, preview: Double?,
                       in root: URL = root) throws -> Self {
        let id = UUID()
        let directory = root.appendingPathComponent(id.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var excluded = directory
        var values = URLResourceValues(); values.isExcludedFromBackup = true
        try? excluded.setResourceValues(values)
        let owned = directory.appendingPathComponent("source." + source.pathExtension)
        do {
            try FileManager.default.copyItem(at: source, to: owned)
            let job = Self(id: id, originalSource: source, source: owned, title: title,
                           cloud: cloud, previewTime: preview, automaticResume: true)
            try job.save(in: root)
            return job
        } catch { try? FileManager.default.removeItem(at: directory); throw error }
    }
    func save(in root: URL = root) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try JSONEncoder().encode(self).write(to: root.appendingPathComponent("active.json"), options: .atomic)
    }
    func remove(in root: URL = root) {
        if Self.load(in: root)?.id == id { try? FileManager.default.removeItem(at: root.appendingPathComponent("active.json")) }
        try? FileManager.default.removeItem(at: root.appendingPathComponent(id.uuidString))
    }
}

/// Completed model segments are durable and checksummed. Replaying their
/// overlap-add is inexpensive and preserves the original DSP exactly.
enum StemSegmentCheckpoint {
    static func load(_ url: URL, count: Int) -> [Float]? {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe), data.count == count * 4,
              let digest = try? String(contentsOf: url.appendingPathExtension("sha256")),
              SHA256.hash(data: data).map({ String(format: "%02x", $0) }).joined() == digest else { return nil }
        var result = [Float](repeating: 0, count: count)
        _ = result.withUnsafeMutableBytes { data.copyBytes(to: $0) }
        return result.allSatisfy(\.isFinite) ? result : nil
    }
    static func save(_ samples: [Float], to url: URL) throws {
        let data = samples.withUnsafeBytes { Data($0) }
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        try data.write(to: url, options: .atomic)
        try digest.write(to: url.appendingPathExtension("sha256"), atomically: true, encoding: .utf8)
    }
}
