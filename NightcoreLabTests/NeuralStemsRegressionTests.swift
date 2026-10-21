import AVFoundation
import AudioToolbox
import CoreML
import UIKit
import XCTest
@testable import NightcoreLab

final class NeuralStemsRegressionTests: XCTestCase {
    private var folder: URL!
    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("NeuralStemsTest-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: folder) }

    private func write(_ name: String, rate: Double = 44_100, channels: UInt32 = 2,
                       sample: (Int) -> Float) throws -> URL {
        let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: channels)!
        let count = Int(rate * 2)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count))!
        buffer.frameLength = AVAudioFrameCount(count)
        for channel in 0..<Int(channels) {
            for i in 0..<count { buffer.floatChannelData![channel][i] = sample(i) }
        }
        let url = folder.appendingPathComponent(name + ".wav")
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
        return url
    }
    private func samples(_ url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
        try file.read(into: buffer)
        return Array(UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength)))
    }
    private func amplitude(_ wave: [Float], frequency: Double) -> Double {
        let start = 8_820, count = 44_100
        var real = 0.0, imag = 0.0
        for i in start..<(start + count) {
            let phase = 2 * Double.pi * frequency * Double(i) / 44_100
            real += Double(wave[i]) * cos(phase); imag += Double(wave[i]) * sin(phase)
        }
        return 2 * hypot(real, imag) / Double(count)
    }

    func testFourFileMixReallyIsolatesVoiceAndMutesOtherSources() throws {
        let frequencies: [StemKind: Double] = [.vocal: 440, .instrumental: 1_000, .drums: 4_000, .bass: 80]
        var urls: [StemKind: URL] = [:]
        for kind in StemKind.allCases {
            let frequency = frequencies[kind]!
            urls[kind] = try write(kind.rawValue) { Float(0.2 * sin(2 * .pi * frequency * Double($0) / 44_100)) }
        }
        let source = try write("original") { index in
            Float(frequencies.values.reduce(0) { $0 + 0.2 * sin(2 * .pi * $1 * Double(index) / 44_100) })
        }
        let settings = RenderSettings(speed: 1, pitch: 0, reverb: 0, bass: 0, reverbPresetRaw: 0)
        let asset = StemAsset(urls: urls, source: .demucs)
        let rendered = try AudioEngineManager.renderOffline(source: source, settings: settings,
            format: .wav, progress: { _ in }, stemLevels: StemMixPreset.acapella.levels, stemAsset: asset)
        defer { try? FileManager.default.removeItem(at: rendered) }
        let output = try samples(rendered)
        XCTAssertGreaterThan(amplitude(output, frequency: 440), 0.1)
        for frequency in [80.0, 1_000, 4_000] {
            XCTAssertLessThan(amplitude(output, frequency: frequency), 0.0001,
                              "Muting a stem must remove its own waveform, not attenuate the original mixture")
        }
        let muted = try AudioEngineManager.renderOffline(source: source, settings: settings,
            format: .wav, progress: { _ in }, stemLevels: Dictionary(uniqueKeysWithValues: StemKind.allCases.map { ($0, Float(0)) }), stemAsset: asset)
        defer { try? FileManager.default.removeItem(at: muted) }
        XCTAssertLessThan(try samples(muted).map { abs($0) }.max() ?? 1, 0.000001)
    }

    func testCanonicalResamplingKeepsMonoGainAndTransientPosition() throws {
        let source = try write("mono48", rate: 48_000, channels: 1) { i in
            i == 24_000 ? 0.8 : 0
        }
        let destination = folder.appendingPathComponent("canonical.caf")
        let decoded = try NeuralStemWorker.decode(source, to: destination, check: {})
        XCTAssertLessThanOrEqual(abs(decoded.frames - 88_200), 2)
        let file = try AVAudioFile(forReading: destination)
        XCTAssertEqual(file.processingFormat.sampleRate, 44_100)
        XCTAssertEqual(file.processingFormat.channelCount, 2)
        let wave = try samples(destination)
        let peak = try XCTUnwrap(wave.indices.max(by: { abs(wave[$0]) < abs(wave[$1]) }))
        XCTAssertLessThanOrEqual(abs(peak - 22_050), 2, "Resampling must not insert leading delay into the stems")
        XCTAssertGreaterThan(wave.map { abs($0) }.max() ?? 0, 0.5)
    }

    func testStemExportStartsAtSelectedSourceTime() throws {
        var urls: [StemKind: URL] = [:]
        for kind in StemKind.allCases {
            urls[kind] = try write("seek-" + kind.rawValue) { index in
                guard kind == .vocal else { return 0 }
                let frequency = index < 44_100 ? 440.0 : 880.0
                return Float(0.2 * sin(2 * .pi * frequency * Double(index) / 44_100))
            }
        }
        let original = try write("seek-original") { _ in 0 }
        let settings = RenderSettings(speed: 1, pitch: 0, reverb: 0, bass: 0, reverbPresetRaw: 0)
        let result = try AudioEngineManager.renderOffline(source: original, settings: settings,
            format: .wav, progress: { _ in }, startTime: 1, maxDuration: 1,
            stemLevels: StemMixPreset.acapella.levels, stemAsset: StemAsset(urls: urls, source: .demucs))
        defer { try? FileManager.default.removeItem(at: result) }
        let wave = try samples(result)
        XCTAssertGreaterThanOrEqual(wave.count, 30_000)
        // A complete 0.5 s window after any graph startup latency.
        let window = Array(wave[4_410..<26_460])
        func level(_ frequency: Double) -> Double {
            var re = 0.0, im = 0.0
            for (i, value) in window.enumerated() {
                let phase = 2 * .pi * frequency * Double(i) / 44_100
                re += Double(value) * cos(phase); im += Double(value) * sin(phase)
            }
            return 2 * hypot(re, im) / Double(window.count)
        }
        XCTAssertGreaterThan(level(880), 0.1)
        XCTAssertLessThan(level(440), 0.0001, "Seeking a stem mix must not replay its beginning")
    }

    func testCPUSelectionProtectsXRAndFourGBDevices() {
        XCTAssertTrue(DemucsCoreMLModel.prefersCPU(physicalMemory: 3 * 1_024 * 1_024 * 1_024))
        XCTAssertTrue(DemucsCoreMLModel.prefersCPU(physicalMemory: 4 * 1_024 * 1_024 * 1_024))
        XCTAssertFalse(DemucsCoreMLModel.prefersCPU(physicalMemory: 6 * 1_024 * 1_024 * 1_024))
    }

    func testComplexPlanesRespectPaddedStridesWithoutFlatteningAllSources() throws {
        let pointer = UnsafeMutablePointer<Float>.allocate(capacity: 128)
        pointer.initialize(repeating: -999, count: 128)
        defer { pointer.deallocate() }
        let array = try MLMultiArray(dataPointer: pointer, shape: [1, 2, 2, 2, 3], dataType: .float32,
                                    strides: [128, 64, 24, 8, 2], deallocator: { _ in })
        let values: [Float] = [1, 2, 3, 4, 5, 6]
        try DemucsCoreMLModel.writePlane(values, to: array, prefix: [0, 1, 1])
        XCTAssertEqual(try DemucsCoreMLModel.readPlane(array, prefix: [0, 1, 1]), values)
        XCTAssertEqual(pointer[89], -999)
        XCTAssertEqual(try DemucsCoreMLModel.readPlane(array, prefix: [0, 0, 0]), Array(repeating: -999, count: 6))
        XCTAssertThrowsError(try DemucsCoreMLModel.readPlane(array, prefix: [0, 2, 0]))
    }

    func testOwnedStageOutputCopiesPaddedStorageAndDoesNotAliasIt() throws {
        let pointer = UnsafeMutablePointer<Float>.allocate(capacity: 16)
        pointer.initialize(repeating: -999, count: 16)
        defer { pointer.deallocate() }
        let values: [Float] = [1, 2, 3, 4, 5, 6]
        for row in 0..<2 { for column in 0..<3 { pointer[row * 8 + column * 2] = values[row * 3 + column] } }
        let source = try MLMultiArray(dataPointer: pointer, shape: [1, 2, 3], dataType: .float32,
                                     strides: [16, 8, 2], deallocator: { _ in })
        let copy = try StagedDemucsPipeline.ownedCopy(source)
        XCTAssertEqual(try DemucsCoreMLModel.readStrided(copy), values)
        pointer.update(repeating: 0, count: 16)
        XCTAssertEqual(try DemucsCoreMLModel.readStrided(copy), values,
                       "An output kept for a later stage must own its bytes after the previous model is released")
    }

    func testNeuralPlayersAllocateOnlyWhenActuallyConnected() {
        let stems = NeuralStemPlayback()
        XCTAssertTrue(stems.nodes.isEmpty, "Normal player startup must not instantiate eight extra audio units")
        let engine = AVAudioEngine(), mixer = AVAudioMixerNode()
        engine.attach(mixer)
        stems.connect(engine: engine, mixer: mixer)
        XCTAssertEqual(stems.nodes.count, 8)
        XCTAssertTrue(stems.nodes.allSatisfy { $0.engine === engine })
        stems.detach(from: engine)
        XCTAssertTrue(stems.nodes.isEmpty)
    }

    func testPaddedMultiArrayUsesAllStrides() throws {
        let pointer = UnsafeMutablePointer<Float>.allocate(capacity: 16)
        pointer.initialize(repeating: -999, count: 16)
        defer { pointer.deallocate() }
        let values: [Float] = [1, 2, 3, 4, 5, 6]
        for row in 0..<2 { for column in 0..<3 { pointer[row * 8 + column * 2] = values[row * 3 + column] } }
        let array = try MLMultiArray(dataPointer: pointer, shape: [1, 2, 3], dataType: .float32,
                                    strides: [16, 8, 2], deallocator: { _ in })
        XCTAssertEqual(try DemucsCoreMLModel.readStrided(array), values)
        try DemucsCoreMLModel.writeStrided(values.map { $0 * 2 }, to: array)
        XCTAssertEqual(try DemucsCoreMLModel.readStrided(array), values.map { $0 * 2 })
        XCTAssertEqual(pointer[1], -999, "Tensor padding must stay untouched")
    }

    func testIndependentGainHasExactMuteAndTransparentUnity() {
        let gain = LinearStemGain(1)
        var left = [Float](repeating: 0.25, count: 2_000), right = left
        func render() {
            let count = left.count
            left.withUnsafeMutableBufferPointer { l in
                right.withUnsafeMutableBufferPointer { r in gain.process(l.baseAddress!, r.baseAddress!, count: count) }
            }
        }
        render(); XCTAssertTrue(left.allSatisfy { $0 == 0.25 })
        gain.set(0); render(); XCTAssertEqual(left.last, 0); XCTAssertEqual(right.last, 0)
        left = [Float](repeating: 0.25, count: 2_000); right = left
        render(); XCTAssertTrue(left.allSatisfy { $0 == 0 })
    }

    func testLiveParameterEventsReachIndependentGain() throws {
        let engine = AVAudioEngine(), player = AVAudioPlayerNode()
        let gain = StemGainAudioUnit.makeNode(initialGain: 1)
        let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2)!
        [player, gain].forEach { engine.attach($0) }
        engine.connect(player, to: gain, format: format)
        engine.connect(gain, to: engine.mainMixerNode, format: format)
        let input = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 44_100)!
        input.frameLength = input.frameCapacity
        for channel in 0..<2 {
            for i in 0..<Int(input.frameLength) {
                input.floatChannelData![channel][i] = 0.1 * sin(2 * .pi * 220 * Float(i) / 44_100)
            }
        }
        try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 4096)
        let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4096)!
        player.scheduleBuffer(input, at: nil, options: .loops)
        try engine.start(); player.play()
        defer { player.stop(); engine.stop() }
        func settledPeak() throws -> Float {
            var peak: Float = -1
            for _ in 0..<5 {
                if try engine.renderOffline(4096, to: output) == .success {
                    peak = (0..<Int(output.frameLength)).reduce(Float(0)) {
                        max($0, abs(output.floatChannelData![0][$1]))
                    }
                }
            }
            return peak
        }
        XCTAssertEqual(try settledPeak(), 0.1, accuracy: 0.0001)
        gain.auAudioUnit.scheduleParameterBlock(AUEventSampleTimeImmediate, 0, 0, 0)
        XCTAssertEqual(try settledPeak(), 0, accuracy: 0.000001)
        gain.auAudioUnit.scheduleParameterBlock(AUEventSampleTimeImmediate, 0, 0, 0.5)
        XCTAssertEqual(try settledPeak(), 0.05, accuracy: 0.0001)
    }

    func testMemoryWarningStopsBeforeLoadingModelAndCleansPartialFiles() async throws {
        let source = try write("memory-warning") { _ in 0.1 }
        let cache = folder.appendingPathComponent("cancelled-cache")
        do {
            _ = try await NeuralStemWorker.prepare(source: source, cacheFolder: cache,
                modelURL: folder.appendingPathComponent("must-not-load.mlmodelc")) { progress, _ in
                if progress == 0.04 {
                    NotificationCenter.default.post(name: UIApplication.didReceiveMemoryWarningNotification, object: nil)
                }
            }
            XCTFail("A memory warning must stop separation before allocating the model")
        } catch NeuralStemError.insufficientMemory {
            let remaining = try FileManager.default.contentsOfDirectory(atPath: cache.path)
            XCTAssertTrue(remaining.isEmpty, "Aborted separation must clean partial files and never commit corrupt stems")
        }
    }

    func testDeliveryContainsAndRunsVerifiedNeuralModel() async throws {
        let environment = ProcessInfo.processInfo.environment
        let required = environment["GNARLY_REQUIRE_NEURAL_MODEL"] == "1" ||
            environment["TEST_RUNNER_GNARLY_REQUIRE_NEURAL_MODEL"] == "1"
        guard let model = NeuralStemWorker.bundledModel else {
            if required { XCTFail("IPA delivery must include the validated HTDemucs model"); return }
            throw XCTSkip("Compile-only simulator gate; full IPA pipeline requires the neural model")
        }
        let evidence = model.deletingLastPathComponent().appendingPathComponent("neural-parity.json")
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: evidence)) as? [String: Any])
        XCTAssertEqual(json["passed"] as? Bool, true)
        XCTAssertEqual((json["sources"] as? [[String: Any]])?.count, 4)
        // Exercise the actual bundled model AND the app's complete worker in
        // the iOS runtime: stereo 44.1k decode, prediction, overlap, four files,
        // atomic cache commit and subsequent reuse without loading a model.
        let source = try write("neural-runtime") {
            Float(0.1 * sin(2 * .pi * 440 * Double($0) / 44_100))
        }
        let cache = folder.appendingPathComponent("runtime-cache")
        let asset = try await NeuralStemWorker.prepare(source: source, cacheFolder: cache,
            modelURL: model, progress: { _, _ in })
        XCTAssertEqual(asset.source, .demucs)
        XCTAssertEqual(try NeuralStemWorker.validate(asset, expectedSeconds: 2), 88_200)
        var peak: Float = 0
        for url in asset.urls.values {
            let wave = try samples(url)
            XCTAssertTrue(wave.allSatisfy { $0.isFinite })
            peak = max(peak, wave.map { abs($0) }.max() ?? 0)
        }
        XCTAssertGreaterThan(peak, 0.001)
        let cached = try await NeuralStemWorker.prepare(source: source, cacheFolder: cache,
            modelURL: nil, progress: { _, _ in })
        XCTAssertEqual(cached.urls, asset.urls)
    }
}
