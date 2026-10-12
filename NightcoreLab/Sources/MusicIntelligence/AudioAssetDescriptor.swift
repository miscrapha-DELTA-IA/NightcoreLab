import AVFoundation
import CryptoKit
import Foundation

/// Identity is independent of Track (local imports do not necessarily have one).
/// The locator identifies the asset; a full content digest identifies its revision.
struct AudioAssetDescriptor: Codable, Equatable, Sendable {
    struct Format: Codable, Equatable, Sendable {
        let sampleRate: Double
        let channelCount: UInt32
        let formatID: UInt32
    }

    let url: URL
    let assetID: String
    let sourceRevision: String
    let duration: TimeInterval
    let format: Format

    var contentSignature: String { sourceRevision }

    static func canonicalURL(_ url: URL) -> URL {
        url.standardizedFileURL.resolvingSymlinksInPath()
    }

    /// Synchronous, bounded-memory I/O. Only call from a utility worker.
    static func read(at source: URL) throws -> AudioAssetDescriptor {
        try Task.checkCancellation()
        guard source.isFileURL else { throw AudioFeatureAnalysisError.unsupportedAudio }
        let url = canonicalURL(source)
        let before = try FileStamp(url)
        let file = try AVAudioFile(forReading: url)
        let rate = file.processingFormat.sampleRate
        guard rate.isFinite, rate > 0, file.length > 0,
              (1...2).contains(file.processingFormat.channelCount) else {
            throw AudioFeatureAnalysisError.unsupportedAudio
        }
        let revision = try signature(at: url)
        guard before == (try FileStamp(url)) else { throw IdentityError.sourceChanged }
        return AudioAssetDescriptor(
            url: url,
            assetID: digest(Data(url.absoluteString.utf8)),
            sourceRevision: revision,
            duration: Double(file.length) / rate,
            format: Format(sampleRate: rate,
                           channelCount: file.processingFormat.channelCount,
                           formatID: file.fileFormat.streamDescription.pointee.mFormatID)
        )
    }

    /// Do not publish/cache a timeline decoded while its source was replaced.
    func validateSource() throws {
        guard try Self.signature(at: url) == sourceRevision else {
            throw IdentityError.sourceChanged
        }
    }

    static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func signature(at url: URL) throws -> String {
        let before = try FileStamp(url)
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        var hash = SHA256()
        while true {
            try Task.checkCancellation()
            let chunk = try file.read(upToCount: 1_048_576) ?? Data()
            if chunk.isEmpty { break }
            hash.update(data: chunk)
        }
        guard before == (try FileStamp(url)) else { throw IdentityError.sourceChanged }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    enum IdentityError: Error { case sourceChanged }

    /// Cheap change detector: size, modification date and inode.
    struct FileStamp: Equatable, Sendable {
        let size: UInt64
        let modified: Date?
        let inode: UInt64

        init(_ url: URL) throws {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            size = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
            modified = attributes[.modificationDate] as? Date
            inode = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0
        }
    }
}

/// Stage 10C: avoid re-hashing an unchanged file.
///
/// `AudioAssetDescriptor.read` and `validateSource` each SHA-256 the whole
/// file; a single analysis request used to hash it 2× on a cache hit and 3× on
/// a miss, and the player and the Story preview request separately. This cache
/// keeps the descriptor per canonical URL together with the FileStamp seen
/// before hashing, and repeats the full hash only when the stamp differs.
/// A change that preserves size, modification date AND inode is not detected;
/// on APFS (nanosecond mtimes) that requires deliberate tampering.
actor AssetIdentityCache {
    private struct Entry {
        let stamp: AudioAssetDescriptor.FileStamp
        let asset: AudioAssetDescriptor
    }

    private var entries: [URL: Entry] = [:]
    private var order: [URL] = []
    private let limit: Int

    init(limit: Int = 64) { self.limit = max(1, limit) }

    /// Same result as `AudioAssetDescriptor.read(at:)`, hashing only when needed.
    func descriptor(for source: URL) throws -> AudioAssetDescriptor {
        guard source.isFileURL else { throw AudioFeatureAnalysisError.unsupportedAudio }
        let url = AudioAssetDescriptor.canonicalURL(source)
        // Taken BEFORE hashing: if the file changes meanwhile, the stored stamp
        // is stale and the next request simply hashes again (conservative).
        let stamp = try AudioAssetDescriptor.FileStamp(url)
        if let entry = entries[url], entry.stamp == stamp { return entry.asset }
        let asset = try AudioAssetDescriptor.read(at: url)
        remember(Entry(stamp: stamp, asset: asset), for: url)
        return asset
    }

    /// Same contract as `asset.validateSource()`; the full hash runs only when
    /// the file's stamp no longer matches the one recorded for this descriptor.
    func validate(_ asset: AudioAssetDescriptor) throws {
        let stamp = try AudioAssetDescriptor.FileStamp(asset.url)
        if let entry = entries[asset.url], entry.asset == asset, entry.stamp == stamp {
            return
        }
        try asset.validateSource()
    }

    private func remember(_ entry: Entry, for url: URL) {
        if entries.updateValue(entry, forKey: url) == nil {
            order.append(url)
            if order.count > limit {
                entries.removeValue(forKey: order.removeFirst())
            }
        }
    }
}
