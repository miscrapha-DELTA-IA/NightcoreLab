import AVFoundation
import CoreML
import CryptoKit
import Darwin
import Foundation
import OSLog

/// Opt-in, offline service. Nothing here attaches a node to the live audio
/// engine or changes playback, microphone capture, karaoke scoring or UI.
actor StemSeparationService {
    static let shared = StemSeparationService(backend: HTDemucsStemBackend())

    private let backend: any StemSeparationBackend
    private let log = Logger(subsystem: "com.nightcorelab.app", category: "StemBenchmark")
    private var state: StemSeparationState = .naoBaixado
    private var isSeparating = false
    private var listeners: [UUID: AsyncStream<StemSeparationState>.Continuation] = [:]

    init(backend: any StemSeparationBackend) { self.backend = backend }

    func states() -> AsyncStream<StemSeparationState> {
        let id = UUID()
        return AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            listeners[id] = continuation
            continuation.yield(state)
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeListener(id) }
            }
        }
    }

    private func removeListener(_ id: UUID) { listeners[id] = nil }

    private func publish(_ next: StemSeparationState) {
        state = next
        for continuation in listeners.values { continuation.yield(next) }
    }

    private func publishDownloadProgress(_ value: Double) {
        guard case .baixando(let current) = state, value > current else { return }
        publish(.baixando(min(1, value)))
    }

    /// Returns local CAF URLs, cached by track ID and model revision. The
    /// caller must pass a local, readable source URL and choose when to run.
    func separate(trackID: String, sourceURL: URL) async throws -> StemURLs {
        guard !isSeparating else { throw StemSeparationError.busy }
        isSeparating = true
        defer { isSeparating = false }
        do {
            let version = await backend.modelVersion
            var stemsRoot = try supportDirectory().appendingPathComponent("Stems", isDirectory: true)
            try FileManager.default.createDirectory(at: stemsRoot, withIntermediateDirectories: true)
            var backupValues = URLResourceValues(); backupValues.isExcludedFromBackup = true
            try stemsRoot.setResourceValues(backupValues)
            var root = stemsRoot
                .appendingPathComponent(Self.safeTrackID(trackID), isDirectory: true)
                .appendingPathComponent(version, isDirectory: true)
            if let cached = Self.cachedStems(at: root) {
                publish(.pronto(cached))
                return cached
            }
            try Task.checkCancellation()
            try await prepareModel()
            let scoped = sourceURL.startAccessingSecurityScopedResource()
            defer { if scoped { sourceURL.stopAccessingSecurityScopedResource() } }
            let temporary = root.deletingLastPathComponent()
                .appendingPathComponent(".\(version)-\(UUID().uuidString).partial", isDirectory: true)
            try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: temporary) }
            let urls = try await process(sourceURL: sourceURL, outputDirectory: temporary)
            try Task.checkCancellation()
            if FileManager.default.fileExists(atPath: root.path) { try FileManager.default.removeItem(at: root) }
            try FileManager.default.moveItem(at: temporary, to: root)
            var values = URLResourceValues(); values.isExcludedFromBackup = true
            try root.setResourceValues(values)
            let ready = StemURLs(vocals: root.appendingPathComponent(urls.vocals.lastPathComponent),
                                 drums: root.appendingPathComponent(urls.drums.lastPathComponent),
                                 bass: root.appendingPathComponent(urls.bass.lastPathComponent),
                                 other: root.appendingPathComponent(urls.other.lastPathComponent))
            publish(.pronto(ready))
            return ready
        } catch {
            publish(.erro(error.localizedDescription))
            throw error
        }
    }

    private func prepareModel() async throws {
        let version = await backend.modelVersion
        let descriptor = await backend.modelDescriptor
        let support = try supportDirectory()
        var modelRoot = support.appendingPathComponent("StemModels", isDirectory: true)
            .appendingPathComponent(version, isDirectory: true)
        let compiled = modelRoot.appendingPathComponent("\(descriptor.packageName).mlmodelc", isDirectory: true)
        if FileManager.default.fileExists(atPath: compiled.path) {
            do {
                try await backend.loadModel(at: compiled)
                return
            } catch {
                try FileManager.default.removeItem(at: compiled)
            }
        }
        let required = descriptor.files.reduce(Int64(0)) { $0 + $1.byteCount } * 3
        let capacity = try support
            .resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            .volumeAvailableCapacityForImportantUsage
        if let capacity, capacity < required { throw StemSeparationError.insufficientStorage }
        try FileManager.default.createDirectory(at: modelRoot, withIntermediateDirectories: true)
        var values = URLResourceValues(); values.isExcludedFromBackup = true
        try modelRoot.setResourceValues(values)
        let package = modelRoot.appendingPathComponent(descriptor.packageName, isDirectory: true)
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        let total = Double(descriptor.files.reduce(Int64(0)) { $0 + $1.byteCount })
        var downloaded: Int64 = 0
        publish(.baixando(0))
        for file in descriptor.files {
            try Task.checkCancellation()
            let target = package.appendingPathComponent(file.path)
            let prior = downloaded
            var attempt = 0
            while true {
                do {
                    _ = try await StemModelDownload.shared.download(
                        from: descriptor.url(for: file), to: target, file: file,
                        progress: { [weak self] fraction in
                            let overall = (Double(prior) + fraction * Double(file.byteCount)) / total
                            Task { await self?.publishDownloadProgress(overall) }
                        })
                    break
                } catch {
                    attempt += 1
                    if Task.isCancelled { throw CancellationError() }
                    if error is CancellationError || attempt >= 3 { throw error }
                    try await Task.sleep(for: .seconds(Double(1 << attempt)))
                }
            }
            downloaded += file.byteCount
            publish(.baixando(Double(downloaded) / total))
        }
        try Task.checkCancellation()
        let temporaryCompiled = try await MLModel.compileModel(at: package)
        try FileManager.default.moveItem(at: temporaryCompiled, to: compiled)
        try? FileManager.default.removeItem(at: package)
        try await backend.loadModel(at: compiled)
    }

    private func process(sourceURL: URL, outputDirectory: URL) async throws -> StemURLs {
        let started = ProcessInfo.processInfo.systemUptime
        let normalized = outputDirectory.appendingPathComponent("source-44100.caf")
        let source = try AVAudioFile(forReading: sourceURL, commonFormat: .pcmFormatFloat32, interleaved: false)
        guard (1...2).contains(source.processingFormat.channelCount), source.length > 0 else {
            throw StemSeparationError.invalidAudio
        }
        let needsConversion = source.processingFormat.channelCount != 2 ||
            abs(source.processingFormat.sampleRate - 44_100) > 0.01
        if needsConversion { try Self.normalize(source: source, to: normalized) }
        defer { if needsConversion { try? FileManager.default.removeItem(at: normalized) } }
        let input = needsConversion
            ? try AVAudioFile(forReading: normalized, commonFormat: .pcmFormatFloat32, interleaved: false)
            : source
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 44_100,
                                   channels: 2, interleaved: false)!
        let urls = StemURLs(vocals: outputDirectory.appendingPathComponent("vocals.caf"),
                            drums: outputDirectory.appendingPathComponent("drums.caf"),
                            bass: outputDirectory.appendingPathComponent("bass.caf"),
                            other: outputDirectory.appendingPathComponent("other.caf"))
        var files = try Dictionary(uniqueKeysWithValues: StemKind.allCases.map { stem in
            (stem, try AVAudioFile(forWriting: urls[stem], settings: format.settings,
                                   commonFormat: .pcmFormatFloat32, interleaved: false))
        })
        let frames = Int(input.length)
        let chunkSize = await backend.chunkFrames
        let overlap = await backend.overlapFrames
        guard chunkSize > overlap, overlap > 0, frames > 0 else { throw StemSeparationError.invalidAudio }
        let stride = chunkSize - overlap
        let chunkCount = (frames - 1) / stride + 1
        var previousTail: [StemKind: StereoStemChunk] = [:]
        publish(.processando(0, eta: nil))

        for index in 0..<chunkCount {
            try Task.checkCancellation()
            try await waitForThermalBudget(progress: Double(index) / Double(chunkCount))
            let start = index * stride
            let valid = min(chunkSize, frames - start)
            input.framePosition = AVAudioFramePosition(start)
            guard let buffer = AVAudioPCMBuffer(pcmFormat: input.processingFormat,
                                                frameCapacity: AVAudioFrameCount(chunkSize)) else {
                throw StemSeparationError.invalidAudio
            }
            try input.read(into: buffer, frameCount: AVAudioFrameCount(valid))
            guard Int(buffer.frameLength) == valid, let channels = buffer.floatChannelData else {
                throw StemSeparationError.invalidAudio
            }
            var left = [Float](repeating: 0, count: chunkSize)
            var right = [Float](repeating: 0, count: chunkSize)
            left.withUnsafeMutableBufferPointer { $0.baseAddress!.update(from: channels[0], count: valid) }
            right.withUnsafeMutableBufferPointer { $0.baseAddress!.update(from: channels[1], count: valid) }
            var predicted = try await backend.predict(left: left, right: right)
            try StemAudioMath.enforceMixture(left: left, right: right, stems: &predicted)
            // The model's STFT/iSTFT is internal. Only the time-domain predictions
            // are blended, and at most one previous tail remains in memory.
            for stem in StemKind.allCases {
                guard let current = predicted[stem],
                      current.left.count == chunkSize, current.right.count == chunkSize else {
                    throw StemSeparationError.invalidModelOutput
                }
                let joined = Self.outputSlice(current: current, previous: previousTail[stem],
                                              valid: valid, stride: stride, overlap: overlap)
                try Self.write(joined, to: files[stem]!, format: format)
                if valid > stride {
                    previousTail[stem] = .init(
                        left: Array(current.left[stride..<min(chunkSize, stride + overlap)]),
                        right: Array(current.right[stride..<min(chunkSize, stride + overlap)]))
                } else {
                    previousTail[stem] = nil
                }
            }
            let elapsed = ProcessInfo.processInfo.systemUptime - started
            let fraction = Double(index + 1) / Double(chunkCount)
            publish(.processando(fraction, eta: elapsed / fraction - elapsed))
            let audioMinutes = Double(frames) / 44_100 / 60
            log.info("stems chunk=\(index + 1)/\(chunkCount) secondsPerAudioMinute=\(elapsed / audioMinutes, format: .fixed(precision: 2)) peakRSSBytes=\(Self.peakRSS()) thermal=\(ProcessInfo.processInfo.thermalState.rawValue) lowPower=\(ProcessInfo.processInfo.isLowPowerModeEnabled)")
        }
        files.removeAll() // Close CAF writers before validating or moving their files.
        guard Self.cachedStems(at: outputDirectory) != nil else { throw StemSeparationError.invalidAudio }
        return urls
    }

    private func waitForThermalBudget(progress: Double) async throws {
        while ProcessInfo.processInfo.thermalState == .serious ||
                ProcessInfo.processInfo.thermalState == .critical ||
                ProcessInfo.processInfo.isLowPowerModeEnabled {
            publish(.pausado("Aguardando o iPhone esfriar ou o Modo de Pouca Energia ser desativado."))
            try await Task.sleep(for: .seconds(5))
        }
        publish(.processando(progress, eta: nil))
    }

    private static func outputSlice(current: StereoStemChunk, previous: StereoStemChunk?,
                                    valid: Int, stride: Int, overlap: Int) -> StereoStemChunk {
        let writeCount = min(valid, stride)
        // The preceding chunk wrote through its stride; its withheld tail
        // occupies the beginning of this chunk.
        let blendCount = previous == nil ? 0 : min(overlap, valid)
        let length = previous == nil ? writeCount : min(valid, overlap + max(0, writeCount - overlap))
        var l = [Float](repeating: 0, count: length)
        var r = [Float](repeating: 0, count: length)
        if let previous {
            for i in 0..<blendCount {
                l[i] = StemAudioMath.crossfade(previous: previous.left[i], next: current.left[i],
                                               index: i, count: overlap)
                r[i] = StemAudioMath.crossfade(previous: previous.right[i], next: current.right[i],
                                               index: i, count: overlap)
            }
            if length > blendCount {
                for i in blendCount..<length { l[i] = current.left[i]; r[i] = current.right[i] }
            }
        } else {
            for i in 0..<length { l[i] = current.left[i]; r[i] = current.right[i] }
        }
        return .init(left: l, right: r)
    }

    private static func write(_ chunk: StereoStemChunk, to file: AVAudioFile,
                              format: AVAudioFormat) throws {
        guard !chunk.left.isEmpty else { return }
        let count = chunk.left.count
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count)),
              let channels = buffer.floatChannelData else { throw StemSeparationError.invalidAudio }
        buffer.frameLength = AVAudioFrameCount(count)
        chunk.left.withUnsafeBufferPointer { channels[0].update(from: $0.baseAddress!, count: count) }
        chunk.right.withUnsafeBufferPointer { channels[1].update(from: $0.baseAddress!, count: count) }
        try file.write(from: buffer)
    }

    private static func normalize(source: AVAudioFile, to url: URL) throws {
        guard let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 44_100,
                                         channels: 2, interleaved: false),
              let converter = AVAudioConverter(from: source.processingFormat, to: target) else {
            throw StemSeparationError.invalidAudio
        }
        let output = try AVAudioFile(forWriting: url, settings: target.settings,
                                      commonFormat: .pcmFormatFloat32, interleaved: false)
        var ended = false
        var emptyPasses = 0
        repeat {
            try Task.checkCancellation()
            guard let buffer = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: 8_192) else {
                throw StemSeparationError.invalidAudio
            }
            var readError: Error?
            var conversionError: NSError?
            let status = converter.convert(to: buffer, error: &conversionError) { requested, inputStatus in
                guard let incoming = AVAudioPCMBuffer(pcmFormat: source.processingFormat,
                                                       frameCapacity: max(requested, 1)) else {
                    inputStatus.pointee = .noDataNow
                    return nil
                }
                do { try source.read(into: incoming, frameCount: requested) }
                catch { readError = error; inputStatus.pointee = .noDataNow; return nil }
                if incoming.frameLength == 0 { inputStatus.pointee = .endOfStream; return nil }
                inputStatus.pointee = .haveData
                return incoming
            }
            if let readError { throw readError }
            if let conversionError { throw conversionError }
            if buffer.frameLength > 0 { try output.write(from: buffer) }
            emptyPasses = buffer.frameLength == 0 ? emptyPasses + 1 : 0
            if emptyPasses > 3 && status != .endOfStream { throw StemSeparationError.invalidAudio }
            ended = status == .endOfStream
        } while !ended
    }

    private func supportDirectory() throws -> URL {
        try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                    appropriateFor: nil, create: true)
    }

    private static func safeTrackID(_ raw: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        if !raw.isEmpty, raw.count <= 80,
           raw.unicodeScalars.allSatisfy({ allowed.contains($0) }) { return raw }
        let safe = raw.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) || $0 == "-" || $0 == "_"
            ? String($0) : "_" }.joined()
        let digest = SHA256.hash(data: Data(raw.utf8)).prefix(6)
            .map { String(format: "%02x", $0) }.joined()
        return "\(String(safe.prefix(72)))-\(digest)"
    }

    private static func cachedStems(at root: URL) -> StemURLs? {
        let urls = StemURLs(vocals: root.appendingPathComponent("vocals.caf"),
                            drums: root.appendingPathComponent("drums.caf"),
                            bass: root.appendingPathComponent("bass.caf"),
                            other: root.appendingPathComponent("other.caf"))
        let lengths = StemKind.allCases.compactMap { try? AVAudioFile(forReading: urls[$0]).length }
        guard lengths.count == 4, let first = lengths.first, first > 0,
              lengths.allSatisfy({ $0 == first }) else { return nil }
        return urls
    }

    private static func peakRSS() -> Int64 {
        var usage = rusage()
        return getrusage(RUSAGE_SELF, &usage) == 0 ? Int64(usage.ru_maxrss) : -1
    }
}
