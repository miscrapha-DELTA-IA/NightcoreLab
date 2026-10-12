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

    private struct FileStamp: Equatable {
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
