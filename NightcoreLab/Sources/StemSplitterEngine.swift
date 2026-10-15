import AVFoundation
import CryptoKit
import Foundation

enum StemKind: String, CaseIterable, Codable, Identifiable, Sendable {
    case vocal, instrumental, drums, bass
    var id: String { rawValue }
    var title: String {
        switch self {
        case .vocal: return "🎤 Voz"
        case .instrumental: return "🎸 Inst"
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

struct StemAsset: Sendable {
    let urls: [StemKind: URL]
    var vocalURL: URL? { urls[.vocal] }
}

/// Optional verified model slot. A model may replace the native DSP outputs,
/// but its SHA-256 must match a bundled manifest before it can process audio.
protocol StemModelProvider: Sendable {
    var modelURL: URL { get }
    var expectedSHA256: String { get }
    func separate(source: URL, destination: URL) async throws -> StemAsset
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
        mutating func split(left: Float, right: Float) -> [StemKind: (Float, Float)] {
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
            return [.vocal: (Float(vocal), Float(vocal)),
                    .bass: (Float(bass), Float(bass)),
                    .drums: (Float(drum), Float(drum)),
                    .instrumental: (Float(bedL), Float(bedR))]
        }
    }

    static func verified(_ provider: any StemModelProvider) -> Bool {
        guard let data = try? Data(contentsOf: provider.modelURL) else { return false }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() ==
            provider.expectedSHA256.lowercased()
    }

    /// Runs on a utility task, never in the render callback. The original song
    /// remains audible while the cache is populated.
    static func prepare(source: URL, cacheFolder: URL,
                        model: (any StemModelProvider)? = nil) async throws -> StemAsset {
        if let model, verified(model) {
            return try await model.separate(source: source, destination: cacheFolder)
        }
        return try await StemPreparationCoordinator.shared.prepare(
            source: source, cacheFolder: cacheFolder)
    }

    fileprivate static func prepareNative(source: URL, cacheFolder: URL) throws -> StemAsset {
        let fingerprint = try source.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        let identity = "\(source.path)|\(fingerprint.fileSize ?? 0)|\(fingerprint.contentModificationDate?.timeIntervalSince1970 ?? 0)|v1"
        let key = SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined()
        let folder = cacheFolder.appendingPathComponent("stems-" + key, isDirectory: true)
        let urls = Dictionary(uniqueKeysWithValues: StemKind.allCases.map {
            ($0, folder.appendingPathComponent($0.rawValue + ".caf"))
        })
        if urls.values.allSatisfy({ FileManager.default.fileExists(atPath: $0.path) }) {
            return StemAsset(urls: urls)
        }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        do {
            let input = try AVAudioFile(forReading: source, commonFormat: .pcmFormatFloat32,
                                        interleaved: false)
            let rate = input.processingFormat.sampleRate
            let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2)!
            let writers = try Dictionary(uniqueKeysWithValues: StemKind.allCases.map { kind in
                (kind, try AVAudioFile(forWriting: urls[kind]!, settings: format.settings,
                                       commonFormat: .pcmFormatFloat32, interleaved: false))
            })
            guard let inputBuffer = AVAudioPCMBuffer(pcmFormat: input.processingFormat,
                                                     frameCapacity: 4096),
                  let inputL = inputBuffer.floatChannelData?[0] else {
                throw CocoaError(.fileReadCorruptFile)
            }
            let outputBuffers = Dictionary(uniqueKeysWithValues: StemKind.allCases.compactMap { kind in
                AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4096).map { (kind, $0) }
            })
            var filters = Filters(rate: rate)
            while true {
                try Task.checkCancellation()
                try input.read(into: inputBuffer)
                let count = Int(inputBuffer.frameLength)
                if count == 0 { break }
                for buffer in outputBuffers.values { buffer.frameLength = AVAudioFrameCount(count) }
                let inputR = inputBuffer.floatChannelData?[input.processingFormat.channelCount == 2 ? 1 : 0] ?? inputL
                for frame in 0..<count {
                    let values = filters.split(left: inputL[frame], right: inputR[frame])
                    for kind in StemKind.allCases {
                        guard let value = values[kind], let channels = outputBuffers[kind]?.floatChannelData else { continue }
                        channels[0][frame] = value.0
                        channels[1][frame] = value.1
                    }
                }
                for kind in StemKind.allCases {
                    try writers[kind]!.write(from: outputBuffers[kind]!)
                }
            }
            return StemAsset(urls: urls)
        } catch {
            try? FileManager.default.removeItem(at: folder)
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
    func prepare(source: URL, cacheFolder: URL) throws -> StemAsset {
        try StemSplitterEngine.prepareNative(source: source, cacheFolder: cacheFolder)
    }
}
