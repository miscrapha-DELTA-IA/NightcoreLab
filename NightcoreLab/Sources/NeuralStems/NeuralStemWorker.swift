import AVFoundation
import Accelerate
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
        private let lifecycle: StemWorkLifecycle
        init(lifecycle: StemWorkLifecycle) { self.lifecycle = lifecycle }
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
            try lifecycle.check()
        }
    }
    private struct Manifest: Codable {
        let model: String
        let sourceHash: String
        let frames: Int64
        let previewStart: Double?
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
                        request: NeuralStemRequest = .full,
                        reclaimMemory: @escaping @Sendable () -> Void = {},
                        lifecycle: StemWorkLifecycle = StemWorkLifecycle(),
                        progress: @escaping @Sendable (Double, String) -> Void) async throws -> StemAsset {
        while true {
            try await lifecycle.waitForForeground()
            do {
                return try await prepareAttempt(source: source, cacheFolder: cacheFolder, modelURL: modelURL,
                    request: request, reclaimMemory: reclaimMemory, lifecycle: lifecycle, progress: progress)
            } catch is StemWorkLifecycle.Paused {
                progress(-1, "Pausado em segundo plano · progresso salvo; retoma ao voltar")
            }
        }
    }

    private static func prepareAttempt(source: URL, cacheFolder: URL, modelURL: URL?,
                        request: NeuralStemRequest,
                        reclaimMemory: @escaping @Sendable () -> Void,
                        lifecycle: StemWorkLifecycle,
                        progress: @escaping @Sendable (Double, String) -> Void) async throws -> StemAsset {
        let cancellation = Cancellation(lifecycle: lifecycle)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let memoryObserver = NotificationCenter.default.addObserver(
                    forName: UIApplication.didReceiveMemoryWarningNotification, object: nil, queue: nil
                ) { _ in cancellation.receivedMemoryWarning() }
                queue.async {
                    let result: Result<StemAsset, Error> = autoreleasepool { Result {
                        try cancellation.check()
                        return try run(source: source, cacheFolder: cacheFolder, modelURL: modelURL,
                                       request: request,
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
        var required = try StemKind.allCases.map { kind -> URL in
            guard let url = asset.urls[kind] else { throw NeuralStemError.invalidOutput }
            return url
        }
        if let preview = asset.preview { required += [preview.originalURL, preview.accompanimentURL] }
        for url in required {
            guard url.isFileURL else { throw NeuralStemError.invalidOutput }
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
                            request: NeuralStemRequest,
                            check: () throws -> Void,
                            recover: () throws -> Void,
                            progress: @escaping (Double, String) -> Void) throws -> StemAsset {
        progress(0, "Conferindo música…")
        let input = try AVAudioFile(forReading: source)
        let seconds = Double(input.length) / input.processingFormat.sampleRate
        guard seconds > 0, seconds.isFinite, seconds <= 30 * 60 else { throw NeuralStemError.noAudio }
        let previewStart: Double?
        if let requested = request.previewTime {
            guard requested.isFinite else { throw NeuralStemError.noAudio }
            let clamped = min(max(0, requested), max(0, seconds - 7.8))
            previewStart = Double(Int64(clamped * sampleRate)) / sampleRate
        } else { previewStart = nil }
        let hash = try sourceHash(source, check: check)
        let suffix = previewStart.map { "-preview-\(Int64(($0 * sampleRate).rounded()))" } ?? ""
        let folder = cacheFolder.appendingPathComponent(DemucsCoreMLModel.identifier + "-" + hash + suffix)
        let manifestURL = folder.appendingPathComponent("complete.json")
        if let data = try? Data(contentsOf: manifestURL),
           let manifest = try? JSONDecoder().decode(Manifest.self, from: data),
           manifest.model == DemucsCoreMLModel.identifier, manifest.sourceHash == hash,
           manifest.previewStart == previewStart {
            let asset = makeAsset(folder: folder, frames: manifest.frames, previewStart: previewStart)
            if let count = try? validate(asset), count == manifest.frames {
                progress(1, previewStart == nil ? "Stems prontos no iPhone" : "Prévia pronta para ouvir")
                return asset
            }
        }
        try FileManager.default.createDirectory(at: cacheFolder, withIntermediateDirectories: true)
        let workRoot = cacheFolder == cacheRoot ? StemJobJournal.root : cacheFolder
        let stage = workRoot.appendingPathComponent(".partial-" + DemucsCoreMLModel.identifier + "-" + hash + suffix)
        try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: true)
        // A termination between writing the manifest and renaming the folder
        // must not turn a finished separation into another inference.
        if let data = try? Data(contentsOf: stage.appendingPathComponent("complete.json")),
           let manifest = try? JSONDecoder().decode(Manifest.self, from: data),
           manifest.model == DemucsCoreMLModel.identifier, manifest.sourceHash == hash,
           manifest.previewStart == previewStart,
           let frames = try? validate(makeAsset(folder: stage, frames: manifest.frames, previewStart: previewStart),
                expectedSeconds: previewStart.map { min(7.8, seconds - $0) } ?? seconds),
           frames == manifest.frames {
            if FileManager.default.fileExists(atPath: folder.path) { try FileManager.default.removeItem(at: folder) }
            try FileManager.default.moveItem(at: stage, to: folder)
            progress(1, "Stems salvos recuperados")
            return makeAsset(folder: folder, frames: frames, previewStart: previewStart)
        }
        var completedResult = false
        defer {
            let segments = stage.appendingPathComponent("segments", isDirectory: true)
            let saved = (try? FileManager.default.contentsOfDirectory(atPath: segments.path))?
                .contains(where: { $0.hasSuffix(".pcm") }) ?? false
            if !completedResult && !saved { try? FileManager.default.removeItem(at: stage) }
        }
        guard let modelURL else { throw NeuralStemError.modelMissing }
        // Four float32 stereo stems + decoded input, with working-space margin.
        let existing = FileManager.default.enumerator(at: stage, includingPropertiesForKeys: [.fileSizeKey])?
            .compactMap { ($0 as? URL).flatMap { try? $0.resourceValues(forKeys: [.fileSizeKey]).fileSize } }
            .reduce(Int64(0)) { $0 + Int64($1) } ?? 0
        let required = max(200_000_000, Int64((previewStart == nil ? seconds : min(7.8, seconds)) * sampleRate * 8 * 12 * 1.15) + 200_000_000 - existing)
        if let free = try? cacheFolder.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            .volumeAvailableCapacityForImportantUsage, free < required {
            throw NeuralStemError.insufficientSpace
        }
        let decodedURL = stage.appendingPathComponent(previewStart == nil ? "source.caf" : "original.wav")
        progress(0.01, "Preparando áudio…")
        let decoded = try autoreleasepool {
            try decode(source, to: decodedURL, previewStart: previewStart, check: check)
        }
        try check()
        progress(0.04, "Preparando separação…")
        try check()
        let separator = try autoreleasepool { try DemucsCoreMLModel(url: modelURL) }
        try check()
        let segments = stage.appendingPathComponent("segments", isDirectory: true)
        try FileManager.default.createDirectory(at: segments, withIntermediateDirectories: true)
        try autoreleasepool {
            try separate(decodedURL, decoded: decoded, separator: separator,
                         destinations: urls(in: stage), segments: segments,
                         check: check, recover: recover, progress: progress)
        }
        try check()
        if previewStart != nil {
            try autoreleasepool { try writeAccompaniment(in: stage, check: check) }
        }
        let staged = makeAsset(folder: stage, frames: Int64(decoded.frames), previewStart: previewStart)
        let frames = try validate(staged, expectedSeconds: previewStart == nil ? seconds : Double(decoded.frames) / sampleRate)
        let manifest = Manifest(model: DemucsCoreMLModel.identifier, sourceHash: hash, frames: frames, previewStart: previewStart)
        try JSONEncoder().encode(manifest).write(to: stage.appendingPathComponent("complete.json"), options: .atomic)
        completedResult = true
        if previewStart == nil { try FileManager.default.removeItem(at: decodedURL) }
        try FileManager.default.removeItem(at: segments)
        try check()
        if FileManager.default.fileExists(atPath: folder.path) { try FileManager.default.removeItem(at: folder) }
        try FileManager.default.moveItem(at: stage, to: folder)
        if previewStart != nil { prunePreviews(in: cacheFolder, keeping: folder) }
        progress(1, previewStart == nil ? "Stems prontos no iPhone" : "Prévia pronta para ouvir")
        return makeAsset(folder: folder, frames: frames, previewStart: previewStart)
    }

    private static func makeAsset(folder: URL, frames: Int64, previewStart: Double?) -> StemAsset {
        let preview = previewStart.map {
            StemPreviewInfo(startTime: $0, duration: Double(frames) / sampleRate,
                            originalURL: folder.appendingPathComponent("original.wav"),
                            accompanimentURL: folder.appendingPathComponent("accompaniment.wav"))
        }
        return StemAsset(urls: urls(in: folder), source: .demucs, preview: preview)
    }

    private static func prunePreviews(in root: URL, keeping current: URL) {
        let manager = FileManager.default
        let candidates = (try? manager.contentsOfDirectory(at: root,
            includingPropertiesForKeys: [.contentModificationDateKey], options: .skipsHiddenFiles)) ?? []
        let older = candidates.filter {
            $0 != current && $0.lastPathComponent.hasPrefix(DemucsCoreMLModel.identifier + "-") &&
            $0.lastPathComponent.contains("-preview-")
        }.sorted {
            let lhs = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let rhs = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return lhs > rhs
        }
        for folder in older.dropFirst(2) { try? manager.removeItem(at: folder) }
    }

    /// Actual drums+bass+other waveforms. No EQ proxy or lossy encoding.
    private static func writeAccompaniment(in folder: URL, check: () throws -> Void) throws {
        let files = try [StemKind.drums, .bass, .instrumental].map {
            try AVAudioFile(forReading: folder.appendingPathComponent($0.rawValue + ".wav"))
        }
        let format = files[0].processingFormat
        let buffers = files.map { _ in AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 8192)! }
        let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 8192)!
        let writer = try AVAudioFile(forWriting: folder.appendingPathComponent("accompaniment.wav"),
                                     settings: format.settings)
        var remaining = files[0].length
        while remaining > 0 {
            try check()
            let count = AVAudioFrameCount(min(remaining, 8192))
            output.frameLength = count
            for channel in 0..<2 { output.floatChannelData![channel].update(repeating: 0, count: Int(count)) }
            for (file, buffer) in zip(files, buffers) {
                try file.read(into: buffer, frameCount: count)
                guard buffer.frameLength == count else { throw NeuralStemError.invalidOutput }
                for channel in 0..<2 {
                    vDSP_vadd(output.floatChannelData![channel], 1, buffer.floatChannelData![channel], 1,
                              output.floatChannelData![channel], 1, vDSP_Length(count))
                }
            }
            try writer.write(from: output)
            remaining -= Int64(count)
        }
    }

    /// One streaming resample, plus whole-mix statistics. Mono is explicitly
    /// duplicated, never attenuated or silently treated as a second channel.
    static func decode(_ source: URL, to destination: URL, previewStart: Double? = nil,
                       check: () throws -> Void) throws -> Decoded {
        let file = try AVAudioFile(forReading: source, commonFormat: .pcmFormatFloat32, interleaved: false)
        if let previewStart {
            guard previewStart.isFinite, previewStart >= 0,
                  previewStart < Double(file.length) / file.processingFormat.sampleRate else { throw NeuralStemError.noAudio }
        }
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
        let startFrame = previewStart.map { Int64($0 * file.processingFormat.sampleRate) } ?? 0
        let endFrame = previewStart == nil ? file.length :
            min(file.length, startFrame + Int64(7.8 * file.processingFormat.sampleRate))
        let maxOutput = previewStart == nil ? Int.max : StemDSP.segmentSamples
        file.framePosition = startFrame
        var total = 0, sum = 0.0, squares = 0.0, ended = false
        while true {
            try check()
            var conversionError: NSError?, readError: Error?
            let status = converter.convert(to: output, error: &conversionError) { packets, state in
                // AVAudioFile can fail with a nil NSError when asked to read
                // beyond EOF. Signal EOF before reading, and drain the
                // converter's remaining resampler frames normally.
                let remaining = endFrame - file.framePosition
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
            let n = min(Int(output.frameLength), maxOutput - total)
            if n > 0, let source = output.floatChannelData, let target = buffer.floatChannelData {
                buffer.frameLength = AVAudioFrameCount(n)
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
            if status == .endOfStream || total >= maxOutput { break }
            if status == .error || (n == 0 && ended) { throw NeuralStemError.noAudio }
        }
        guard total > 0 else { throw NeuralStemError.noAudio }
        let mean = sum / Double(total)
        return Decoded(frames: total, mean: Float(mean),
                       standardDeviation: Float(sqrt(max(1e-12, squares / Double(total) - mean * mean))))
    }

    private static func separate(_ source: URL, decoded: Decoded, separator: DemucsCoreMLModel,
                                 destinations: [StemKind: URL], segments: URL, check: () throws -> Void,
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
        var estimator = StemProgressEstimator()
        var remainingMessage = "Separando · medindo o tempo neste iPhone…"
        while start < decoded.frames {
            try check()
            let segmentStartedAt = ProcessInfo.processInfo.systemUptime
            var recoveredMemory = false
            let valid = min(length, decoded.frames - start)
            let count = start + length >= decoded.frames ? valid : advance
            let checkpoint = segments.appendingPathComponent("\(start).pcm")
            let cached = StemSegmentCheckpoint.load(checkpoint, count: 8 * length)
            let separated: [Float]
            if let cached {
                // Completed segments already contain the exact model output.
                // Resume only replays their overlap; no source read, input
                // normalisation or model scratch allocation is necessary.
                separated = cached
            } else {
                StemMemoryRecovery.releaseUnusedPages()
                file.framePosition = AVAudioFramePosition(start)
                try file.read(into: input, frameCount: AVAudioFrameCount(valid))
                guard Int(input.frameLength) == valid, let channels = input.floatChannelData else { throw NeuralStemError.noAudio }
                var segment = [Float](repeating: 0, count: length * 2)
                segment.withUnsafeMutableBufferPointer { target in
                    var negativeMean = -decoded.mean, deviation = decoded.standardDeviation
                    for channel in 0..<2 {
                        let lane = target.baseAddress! + channel * length
                        vDSP_vsadd(channels[channel], 1, &negativeMean, lane, 1, vDSP_Length(valid))
                        vDSP_vsdiv(lane, 1, &deviation, lane, 1, vDSP_Length(valid))
                    }
                }
                separated = try StemMemoryRecovery.perform(recover: { _ in
                    recoveredMemory = true
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
                try StemSegmentCheckpoint.save(separated, to: checkpoint)
            }
            OverlapAdd.accumulate(separated, weight: weight, accumulator: &accumulator, weights: &weights)
            output.frameLength = AVAudioFrameCount(count)
            for source in 0..<4 {
                accumulator.withUnsafeBufferPointer { accumulated in
                    weights.withUnsafeBufferPointer { total in
                        for channel in 0..<2 {
                            let offset = (source * 2 + channel) * length
                            OverlapAdd.restoreLane(accumulated.baseAddress! + offset, weights: total.baseAddress!,
                                count: count, standardDeviation: decoded.standardDeviation, mean: decoded.mean,
                                to: output.floatChannelData![channel])
                        }
                    }
                }
                try writers[source].write(from: output)
            }
            if cached == nil {
                estimator.record(seconds: ProcessInfo.processInfo.systemUptime - segmentStartedAt,
                                 recoveredMemory: recoveredMemory)
            }
            let segmentsLeft = Int(ceil(Double(decoded.frames - start - count) / Double(advance)))
            if segmentsLeft > 0 {
                remainingMessage = estimator.message(segments: segmentsLeft)
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
