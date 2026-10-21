import AVFoundation
import CryptoKit
import Foundation
import Darwin
import os
import UIKit

/// Serial, bounded-memory processing. Only this queue owns the model, files,
/// and overlap-add buffers; nothing runs in an audio callback or on MainActor.
enum NeuralStemWorker {
    private static let queue = DispatchQueue(label: "gnarly.neural-stems", qos: .utility,
                                             autoreleaseFrequency: .workItem)
    static let sampleRate = 44_100.0
    static var bundledModel: URL? {
        Bundle.main.url(forResource: "pipeline", withExtension: "json", subdirectory: "NeuralStems/htdemucs_staged")?
            .deletingLastPathComponent()
    }
    private final class Cancellation: @unchecked Sendable {
        private let lock = NSLock()
        private var cancelled = false
        private var memoryPressure = false
        func cancel() { lock.lock(); cancelled = true; lock.unlock() }
        func receivedMemoryWarning() { lock.lock(); memoryPressure = true; lock.unlock() }
        func resetMemoryPressure() { lock.lock(); memoryPressure = false; lock.unlock() }
        func checkCancellation() throws {
            lock.lock(); let value = cancelled; lock.unlock()
            if value { throw CancellationError() }
        }
        func check() throws {
            lock.lock(); let value = cancelled, memory = memoryPressure; lock.unlock()
            if memory { throw NeuralStemError.insufficientMemory }
            if value { throw CancellationError() }
        }
    }
    private struct Manifest: Codable {
        let model: String
        let sourceHash: String
        let frames: Int64
    }
    struct Decoded {
        let frames: Int
        let mean: Float
        let standardDeviation: Float
    }
    static var cacheRoot: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("GnarlyNeuralStems", isDirectory: true)
    }

    static func prepare(source: URL, cacheFolder: URL = cacheRoot,
                        modelURL: URL? = bundledModel,
                        reclaimMemory: @escaping @Sendable () -> Void = {},
                        progress: @escaping @Sendable (Double, String) -> Void) async throws -> StemAsset {
        let cancellation = Cancellation()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let memoryObserver = NotificationCenter.default.addObserver(
                    forName: UIApplication.didReceiveMemoryWarningNotification, object: nil, queue: nil
                ) { _ in cancellation.receivedMemoryWarning() }
                queue.async {
                    let result: Result<StemAsset, Error> = autoreleasepool { Result {
                        try cancellation.check()
                        return try run(source: source, cacheFolder: cacheFolder, modelURL: modelURL,
                                       check: cancellation.check, recover: {
                            cancellation.resetMemoryPressure()
                            reclaimMemory()
                            StemMemoryRecovery.releaseUnusedPages()
                            // Give UI cache cleanup a bounded opportunity to finish.
                            // This sleeps only the utility worker, never MainActor.
                            for _ in 0..<10 {
                                try cancellation.checkCancellation()
                                Thread.sleep(forTimeInterval: 0.1)
                            }
                            cancellation.resetMemoryPressure()
                        }, progress: progress)
                    } }
                    NotificationCenter.default.removeObserver(memoryObserver)
                    // Drain the ENTIRE job before the UI starts another task.
                    // A queue's .workItem pool drains AFTER continuation.resume.
                    StemMemoryRecovery.releaseUnusedPages()
                    continuation.resume(with: result)
                }
            }
        } onCancel: { cancellation.cancel() }
    }

    private static func sourceHash(_ source: URL, check: () throws -> Void) throws -> String {
        let file = try FileHandle(forReadingFrom: source)
        defer { try? file.close() }
        var hash = SHA256()
        while let data = try file.read(upToCount: 512 * 1024), !data.isEmpty {
            try check(); hash.update(data: data)
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
    private static func urls(in folder: URL) -> [StemKind: URL] {
        Dictionary(uniqueKeysWithValues: StemKind.allCases.map {
            ($0, folder.appendingPathComponent($0.rawValue + ".wav"))
        })
    }

    static func validate(_ asset: StemAsset, expectedSeconds: Double? = nil) throws -> Int64 {
        var frames: AVAudioFramePosition?
        for kind in StemKind.allCases {
            guard let url = asset.urls[kind], url.isFileURL else { throw NeuralStemError.invalidOutput }
            let file = try AVAudioFile(forReading: url)
            guard file.processingFormat.channelCount == 2,
                  file.processingFormat.sampleRate == sampleRate, file.length > 0,
                  frames == nil || frames == file.length else { throw NeuralStemError.invalidOutput }
            frames = file.length
        }
        guard let frames else { throw NeuralStemError.invalidOutput }
        if let expectedSeconds, abs(Double(frames) / sampleRate - expectedSeconds) > 0.1 {
            throw NeuralStemError.invalidOutput
        }
        return frames
    }

    private static func run(source: URL, cacheFolder: URL, modelURL: URL?,
                            check: () throws -> Void,
                            recover: () throws -> Void,
                            progress: @escaping (Double, String) -> Void) throws -> StemAsset {
        progress(0, "Conferindo música…")
        let hash = try sourceHash(source, check: check)
        let folder = cacheFolder.appendingPathComponent(DemucsCoreMLModel.identifier + "-" + hash)
        let manifestURL = folder.appendingPathComponent("complete.json")
        if let data = try? Data(contentsOf: manifestURL),
           let manifest = try? JSONDecoder().decode(Manifest.self, from: data),
           manifest.model == DemucsCoreMLModel.identifier, manifest.sourceHash == hash {
            let asset = StemAsset(urls: urls(in: folder), source: .demucs)
            if let count = try? validate(asset), count == manifest.frames {
                progress(1, "Stems prontos no iPhone")
                return asset
            }
        }
        guard let modelURL else { throw NeuralStemError.modelMissing }
        try FileManager.default.createDirectory(at: cacheFolder, withIntermediateDirectories: true)
        let stage = cacheFolder.appendingPathComponent(".partial-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: stage) }
        let input = try AVAudioFile(forReading: source)
        let seconds = Double(input.length) / input.processingFormat.sampleRate
        guard seconds > 0, seconds.isFinite, seconds <= 30 * 60 else { throw NeuralStemError.noAudio }
        // Four float32 stereo stems + decoded input, with working-space margin.
        let required = Int64(seconds * sampleRate * 8 * 5 * 1.15) + 200_000_000
        if let free = try? cacheFolder.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            .volumeAvailableCapacityForImportantUsage, free < required {
            throw NeuralStemError.insufficientSpace
        }
        let decodedURL = stage.appendingPathComponent("source.caf")
        progress(0.01, "Preparando áudio…")
        let decoded = try decode(source, to: decodedURL, check: check)
        try check()
        progress(0.04, "Preparando separação…")
        try check()
        let separator = try autoreleasepool { try DemucsCoreMLModel(url: modelURL) }
        try check()
        try separate(decodedURL, decoded: decoded, separator: separator,
                     destinations: urls(in: stage), check: check, recover: recover, progress: progress)
        try check()
        let staged = StemAsset(urls: urls(in: stage), source: .demucs)
        let frames = try validate(staged, expectedSeconds: seconds)
        let manifest = Manifest(model: DemucsCoreMLModel.identifier, sourceHash: hash, frames: frames)
        try JSONEncoder().encode(manifest).write(to: stage.appendingPathComponent("complete.json"), options: .atomic)
        try FileManager.default.removeItem(at: decodedURL)
        try check()
        if FileManager.default.fileExists(atPath: folder.path) { try FileManager.default.removeItem(at: folder) }
        try FileManager.default.moveItem(at: stage, to: folder)
        progress(1, "Stems prontos no iPhone")
        return StemAsset(urls: urls(in: folder), source: .demucs)
    }

    /// One streaming resample, plus whole-mix statistics. Mono is explicitly
    /// duplicated, never attenuated or silently treated as a second channel.
    static func decode(_ source: URL, to destination: URL, check: () throws -> Void) throws -> Decoded {
        let file = try AVAudioFile(forReading: source, commonFormat: .pcmFormatFloat32, interleaved: false)
        let channels = file.processingFormat.channelCount
        guard (1...2).contains(channels), file.length > 0,
              let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: channels),
              let stereo = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2),
              let converter = AVAudioConverter(from: file.processingFormat, to: format),
              let input = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 8192),
              let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 8192),
              let buffer = AVAudioPCMBuffer(pcmFormat: stereo, frameCapacity: 8192) else { throw NeuralStemError.noAudio }
        let writer = try AVAudioFile(forWriting: destination, settings: stereo.settings,
                                     commonFormat: .pcmFormatFloat32, interleaved: false)
        var total = 0, sum = 0.0, squares = 0.0, ended = false
        while true {
            try check()
            var conversionError: NSError?, readError: Error?
            let status = converter.convert(to: output, error: &conversionError) { packets, state in
                // AVAudioFile can fail with a nil NSError when asked to read
                // beyond EOF. Signal EOF before reading, and drain the
                // converter's remaining resampler frames normally.
                let remaining = file.length - file.framePosition
                if ended || remaining <= 0 { ended = true; state.pointee = .endOfStream; return nil }
                let count = AVAudioFrameCount(min(Int64(min(packets, input.frameCapacity)), remaining))
                guard count > 0 else { state.pointee = .noDataNow; return nil }
                do {
                    try file.read(into: input, frameCount: count)
                    if input.frameLength == 0 { ended = true; state.pointee = .endOfStream; return nil }
                    state.pointee = .haveData; return input
                } catch { readError = error; state.pointee = .endOfStream; return nil }
            }
            if let readError { throw readError }
            if let conversionError { throw conversionError }
            let n = Int(output.frameLength)
            if n > 0, let source = output.floatChannelData, let target = buffer.floatChannelData {
                buffer.frameLength = output.frameLength
                target[0].update(from: source[0], count: n)
                target[1].update(from: source[Int(channels) - 1], count: n)
                for i in 0..<n {
                    let left = Double(target[0][i]), right = Double(target[1][i])
                    guard left.isFinite && right.isFinite else { throw NeuralStemError.noAudio }
                    sum += (left + right) * 0.5
                    squares += (left * left + right * right) * 0.5
                }
                total += n; try writer.write(from: buffer)
            }
            if status == .endOfStream { break }
            if status == .error || (n == 0 && ended) { throw NeuralStemError.noAudio }
        }
        guard total > 0 else { throw NeuralStemError.noAudio }
        let mean = sum / Double(total)
        return Decoded(frames: total, mean: Float(mean),
                       standardDeviation: Float(sqrt(max(1e-12, squares / Double(total) - mean * mean))))
    }

    private static func separate(_ source: URL, decoded: Decoded, separator: DemucsCoreMLModel,
                                 destinations: [StemKind: URL], check: () throws -> Void,
                                 recover: () throws -> Void,
                                 progress: @escaping (Double, String) -> Void) throws {
        let file = try AVAudioFile(forReading: source, commonFormat: .pcmFormatFloat32, interleaved: false)
        let length = StemDSP.segmentSamples
        let advance = OverlapAdd.stride()
        let weight = OverlapAdd.triangleWeights(length)
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2)!
        let input = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(length))!
        let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(length))!
        // Keep Float32 on disk: no AAC priming, independent rescaling or clipping.
        let order: [StemKind] = [.drums, .bass, .instrumental, .vocal]
        let writers = try order.map {
            try AVAudioFile(forWriting: destinations[$0]!, settings: format.settings,
                            commonFormat: .pcmFormatFloat32, interleaved: false)
        }
        var accumulator = [Float](repeating: 0, count: 8 * length)
        var weights = [Float](repeating: 0, count: length)
        var start = 0
        let startedAt = ProcessInfo.processInfo.systemUptime
        var completedSegments = 0
        var remainingMessage = "Separando voz e instrumentos…"
        while start < decoded.frames {
            StemMemoryRecovery.releaseUnusedPages()
            let valid = min(length, decoded.frames - start)
            let count = start + length >= decoded.frames ? valid : advance
            file.framePosition = AVAudioFramePosition(start)
            try file.read(into: input, frameCount: AVAudioFrameCount(valid))
            guard Int(input.frameLength) == valid, let channels = input.floatChannelData else { throw NeuralStemError.noAudio }
            var segment = [Float](repeating: 0, count: length * 2)
            for channel in 0..<2 {
                for i in 0..<valid { segment[channel * length + i] = (channels[channel][i] - decoded.mean) / decoded.standardDeviation }
            }
            let separated = try StemMemoryRecovery.perform(recover: { _ in
                progress(0.05 + 0.94 * Double(start) / Double(decoded.frames),
                         "Liberando memória para continuar…")
                try recover()
            }) { try autoreleasepool {
                let result = try separator.separate(segment, check: check, admission: { required in
                    #if !targetEnvironment(simulator)
                    let available = os_proc_available_memory()
                    guard available >= required else {
                        throw NeuralStemError.memoryBudget(requiredMiB: required / 1_048_576,
                                                           availableMiB: available / 1_048_576)
                    }
                    #endif
                }, progress: { fraction, _ in
                    // Report committed output, not the overlapping context;
                    // otherwise the bar moves backwards at every segment.
                    let completed = min(Double(decoded.frames), Double(start) + Double(count) * fraction)
                    progress(0.05 + 0.94 * completed / Double(decoded.frames), remainingMessage)
                })
                try check()
                return result
            } }
            for i in 0..<length {
                weights[i] += weight[i]
                for lane in 0..<8 { accumulator[lane * length + i] += separated[lane * length + i] * weight[i] }
            }
            output.frameLength = AVAudioFrameCount(count)
            for source in 0..<4 {
                for channel in 0..<2 {
                    let offset = (source * 2 + channel) * length
                    for i in 0..<count {
                        output.floatChannelData![channel][i] = accumulator[offset + i] / max(weights[i], 1e-12) * decoded.standardDeviation + decoded.mean / 4
                    }
                }
                try writers[source].write(from: output)
            }
            completedSegments += 1
            let segmentsLeft = Int(ceil(Double(decoded.frames - start - count) / Double(advance)))
            if segmentsLeft > 0 {
                let average = (ProcessInfo.processInfo.systemUptime - startedAt) / Double(completedSegments)
                let minutes = max(1, Int(ceil(average * Double(segmentsLeft) / 60)))
                remainingMessage = "Separando no iPhone · cerca de \(minutes) min restantes"
            }
            progress(0.05 + 0.94 * Double(start + count) / Double(decoded.frames), remainingMessage)
            if count == valid { break }
            accumulator.withUnsafeMutableBufferPointer { a in
                for lane in 0..<8 {
                    let pointer = a.baseAddress! + lane * length
                    pointer.update(from: pointer + advance, count: length - advance)
                    (pointer + length - advance).update(repeating: 0, count: advance)
                }
            }
            weights.removeFirst(advance); weights.append(contentsOf: repeatElement(0, count: advance))
            start += advance
        }
    }
}
