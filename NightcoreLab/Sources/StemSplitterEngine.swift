import AVFoundation
import CryptoKit
import Foundation

enum StemKind: String, CaseIterable, Codable, Identifiable, Sendable {
    case vocal, instrumental, drums, bass
    var id: String { rawValue }
    var title: String {
        switch self {
        case .vocal: return "🎤 Voz"
        case .instrumental: return "🎸 Instrumental"
        case .drums: return "🥁 Bateria"
        case .bass: return "🔊 Baixo"
        }
    }
}

enum StemMixPreset: String, CaseIterable, Identifiable {
    case karaoke, acapella, instrumental, rhythm
    var id: String { rawValue }
    var title: String {
        switch self {
        case .karaoke: return "Sem Voz Original"
        case .acapella: return "Só Voz"
        case .instrumental: return "Só Instrumental"
        case .rhythm: return "Bateria & Baixo"
        }
    }
    var levels: [StemKind: Float] {
        switch self {
        case .karaoke: return [.vocal: 0, .instrumental: 1, .drums: 1, .bass: 1]
        case .acapella: return [.vocal: 1, .instrumental: 0, .drums: 0, .bass: 0]
        case .instrumental: return [.vocal: 0, .instrumental: 1, .drums: 0, .bass: 0]
        case .rhythm: return [.vocal: 0, .instrumental: 0.3, .drums: 1, .bass: 1]
        }
    }
}

enum StemSource: String, Sendable { case spectral, demucs }

struct StemAsset: Sendable {
    let urls: [StemKind: URL]
    let source: StemSource
    init(urls: [StemKind: URL], source: StemSource = .spectral) {
        self.urls = urls; self.source = source
    }
    var vocalURL: URL? { urls[.vocal] }
}

enum StemSplitterEngine {
    private struct Filters {
        let bassA: Double, lowA: Double, highA: Double, transientA: Double
        var bass = 0.0, low = 0.0, high = 0.0, transient = 0.0, previousHigh = 0.0
        init(rate: Double) {
            bassA = exp(-2 * .pi * 160 / rate)
            lowA = exp(-2 * .pi * 220 / rate)
            highA = exp(-2 * .pi * 4200 / rate)
            transientA = exp(-2 * .pi * 28 / rate)
        }
        mutating func split(left: Float, right: Float) -> (
            vocal: (Float, Float), instrumental: (Float, Float),
            drums: (Float, Float), bass: (Float, Float)) {
            let l = Double(left), r = Double(right), mid = (l + r) * 0.5
            bass = bassA * bass + (1 - bassA) * mid
            low = lowA * low + (1 - lowA) * mid
            high = highA * high + (1 - highA) * mid
            let vocal = (high - low) * 0.85
            let highBand = mid - high
            let change = abs(highBand - previousHigh)
            transient = transientA * transient + (1 - transientA) * change
            previousHigh = highBand
            let drum = highBand * min(0.85, change / max(0.001, transient * 3))
            let bedL = l - bass - vocal - drum
            let bedR = r - bass - vocal - drum
            return (vocal: (Float(vocal), Float(vocal)),
                    instrumental: (Float(bedL), Float(bedR)),
                    drums: (Float(drum), Float(drum)),
                    bass: (Float(bass), Float(bass)))
        }
    }

    /// Runs on a utility task, never in the render callback. The original song
    /// remains audible while the cache is populated.
    static func prepare(source: URL, cacheFolder: URL,
                        progress: @escaping @Sendable (Int) -> Void = { _ in }) async throws -> StemAsset {
        let cancellation = StemCancellation()
        return try await withTaskCancellationHandler {
            try await StemPreparationCoordinator.shared.prepare(
                source: source, cacheFolder: cacheFolder, progress: progress,
                cancellation: cancellation)
        } onCancel: {
            cancellation.cancel()
        }
    }

    fileprivate static func prepareNative(source: URL, cacheFolder: URL,
                                          progress: @Sendable (Int) -> Void,
                                          cancellation: StemCancellation) throws -> StemAsset {
        if cancellation.isCancelled { throw CancellationError() }
        progress(0)
        let fingerprint = try source.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        let identity = "\(source.path)|\(fingerprint.fileSize ?? 0)|\(fingerprint.contentModificationDate?.timeIntervalSince1970 ?? 0)|\(NativeSpectralStemSeparator.cacheVersion)"
        let key = SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined()
        let folder = cacheFolder.appendingPathComponent("stems-" + key, isDirectory: true)
        let urls: [StemKind: URL] = [
            .instrumental: folder.appendingPathComponent("instrumental.caf"),
            .vocal: folder.appendingPathComponent("vocals.caf")
        ]
        let instrumental = urls[.instrumental]!
        let vocals = urls[.vocal]!
        if FileManager.default.fileExists(atPath: instrumental.path),
           FileManager.default.fileExists(atPath: vocals.path) {
            progress(100)
            return StemAsset(urls: urls)
        }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let temporaryInstrumental = folder.appendingPathComponent(UUID().uuidString + "-instrumental.caf")
        let temporaryVocals = folder.appendingPathComponent(UUID().uuidString + "-vocals.caf")
        defer {
            try? FileManager.default.removeItem(at: temporaryInstrumental)
            try? FileManager.default.removeItem(at: temporaryVocals)
        }
        do {
            try NativeSpectralStemSeparator.separate(
                source: source, instrumentalURL: temporaryInstrumental,
                vocalsURL: temporaryVocals, progress: progress,
                isCancelled: { cancellation.isCancelled })
            if cancellation.isCancelled { throw CancellationError() }
            try? FileManager.default.removeItem(at: instrumental)
            try? FileManager.default.removeItem(at: vocals)
            try FileManager.default.moveItem(at: temporaryInstrumental, to: instrumental)
            try FileManager.default.moveItem(at: temporaryVocals, to: vocals)
            return StemAsset(urls: urls)
        } catch {
            try? FileManager.default.removeItem(at: instrumental)
            try? FileManager.default.removeItem(at: vocals)
            throw error
        }
    }

    static func cosineGain(step: Int, total: Int = 5) -> Float {
        let phase = Double(min(total, max(0, step))) / Double(total)
        return Float((1 - cos(.pi * phase)) * 0.5)
    }
}

private actor StemPreparationCoordinator {
    static let shared = StemPreparationCoordinator()
    private let queue = DispatchQueue(label: "nightcore.stems.offline", qos: .utility)
    func prepare(source: URL, cacheFolder: URL,
                 progress: @escaping @Sendable (Int) -> Void,
                 cancellation: StemCancellation) async throws -> StemAsset {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                continuation.resume(with: Result {
                    try StemSplitterEngine.prepareNative(source: source, cacheFolder: cacheFolder,
                                                         progress: progress,
                                                         cancellation: cancellation)
                })
            }
        }
    }
}

fileprivate final class StemCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func cancel() { lock.lock(); value = true; lock.unlock() }
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return value }
}
