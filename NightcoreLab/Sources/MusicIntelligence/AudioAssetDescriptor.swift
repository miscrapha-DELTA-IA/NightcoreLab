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

    // A content revision must be verified even when all filesystem metadata matches.
    // Internal visibility allows AssetIdentityCache to verify warm descriptors
    // without opening AVAudioFile or decoding the waveform again.
    static func signature(at url: URL) throws -> String {
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

/// A bounded descriptor cache, not a metadata-based trust cache.
///
/// Each *independent* lookup confirms the SHA-256 of the complete source.
/// A matching FileStamp alone can never authorize a cache hit: edits can
/// preserve URL, size, mtime, and inode. On a warm hit, one bounded-memory
/// streaming digest avoids reopening AVAudioFile or re-decoding samples.
/// On a cold lookup, AudioAssetDescriptor.read performs that digest once.
///
/// When correctness requires immediate detection of an arbitrary byte edit,
/// neither periodic checks nor partial hashes are sufficient. This intentionally
/// trades sequential file I/O for source identity correctness; FFT and rhythm
/// analysis remain cached and concurrent requests remain shared by the scheduler.
actor AssetIdentityCache {
    private struct Entry {
        let stamp: AudioAssetDescriptor.FileStamp
        let asset: AudioAssetDescriptor
    }

    private var entries: [URL: Entry] = [:]
    private var order: [URL] = []
    private let limit: Int

    init(limit: Int = 64) { self.limit = max(1, limit) }

    func descriptor(for source: URL) throws -> AudioAssetDescriptor {
        guard source.isFileURL else { throw AudioFeatureAnalysisError.unsupportedAudio }
        let url = AudioAssetDescriptor.canonicalURL(source)
        let stamp = try AudioAssetDescriptor.FileStamp(url)

        if let entry = entries[url], entry.stamp == stamp {
            // Digest all bytes, including the unsampled middle of large files.
            // signature(at:) independently verifies its pre/post filesystem stamp.
            let revision = try AudioAssetDescriptor.signature(at: url)
            guard stamp == (try AudioAssetDescriptor.FileStamp(url)) else {
                forget(url)
                throw AudioAssetDescriptor.IdentityError.sourceChanged
            }
            if revision == entry.asset.sourceRevision { return entry.asset }
        }

        // Never retain a stale descriptor after a content change, even if the
        // replacement is corrupt or can no longer be opened as an audio file.
        forget(url)
        let asset = try AudioAssetDescriptor.read(at: url)
        guard stamp == (try AudioAssetDescriptor.FileStamp(url)) else {
            throw AudioAssetDescriptor.IdentityError.sourceChanged
        }
        remember(Entry(stamp: stamp, asset: asset), for: url)
        return asset
    }

    /// Recheck content before reusing or publishing a decoded timeline. Metadata
    /// equality does not suffice, including during a single analysis job.
    func validate(_ asset: AudioAssetDescriptor) throws {
        do {
            try asset.validateSource()
        } catch {
            forget(asset.url)
            throw error
        }
    }

    private func forget(_ url: URL) {
        if entries.removeValue(forKey: url) != nil {
            order.removeAll { $0 == url }
        }
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
