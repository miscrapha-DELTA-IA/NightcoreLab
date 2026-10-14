import XCTest
import AVFoundation
@testable import NightcoreLab

final class AudioQualityTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    private func source(frequency: Double = 440, amplitude: Float = 0.2,
                        channels: AVAudioChannelCount = 2, seconds: Double = 2) throws -> URL {
        let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: channels)!
        let count = AVAudioFrameCount(seconds * format.sampleRate)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: count)!
        buffer.frameLength = count
        for channel in 0..<Int(channels) {
            for frame in 0..<Int(count) {
                buffer.floatChannelData![channel][frame] =
                    amplitude * Float(sin(2 * Double.pi * frequency * Double(frame) / format.sampleRate))
            }
        }
        let url = folder.appendingPathComponent("source.wav")
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
        return url
    }

    private func render(_ source: URL, speed: Float = 1, preservePitch: Bool = false,
                        bass: Float = 0, reverb: Float = 0, format: ExportFormat = .wav) throws -> URL {
        let settings = RenderSettings(speed: speed, pitch: preservePitch ? 0 : 1200 * log2(speed),
                                      reverb: reverb, bass: bass,
                                      reverbPresetRaw: AVAudioUnitReverbPreset.mediumHall.rawValue)
        let result = try AudioEngineManager.renderOffline(source: source, settings: settings,
                                                          format: format, progress: { _ in })
        addTeardownBlock { try? FileManager.default.removeItem(at: result) }
        return result
    }

    private func samples(_ url: URL) throws -> (AVAudioFile, [Float]) {
        let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
        try file.read(into: buffer)
        return (file, Array(UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength))))
    }

    private func frequency(_ samples: [Float], sampleRate: Double) -> Double {
        let lower = Int(sampleRate * 0.25)
        let upper = min(samples.count - 1, Int(sampleRate * 0.75))
        guard upper > lower else { return 0 }
        let crossings = (lower..<upper).filter { samples[$0] <= 0 && samples[$0 + 1] > 0 }.count
        return Double(crossings) * sampleRate / Double(upper - lower)
    }

    func testTapeModePitchAndDuration() throws {
        let input = try source()
        for speed in [Float(0.5), 0.8, 1, 1.25, 2] {
            let (file, audio) = try samples(render(input, speed: speed))
            let seconds = Double(file.length) / file.processingFormat.sampleRate
            XCTAssertEqual(seconds, 2 / Double(speed) + 0.1, accuracy: 0.03)
            XCTAssertEqual(frequency(audio, sampleRate: file.processingFormat.sampleRate),
                           440 * Double(speed), accuracy: 12)
            XCTAssertTrue(audio.allSatisfy { $0.isFinite })
        }
    }

    func testPreservePitchMode() throws {
        let (file, audio) = try samples(render(source(), speed: 1.25, preservePitch: true))
        XCTAssertEqual(frequency(audio, sampleRate: file.processingFormat.sampleRate), 440, accuracy: 12)
    }

    func testNeutralPathAnd24BitWAV() throws {
        for channels in [AVAudioChannelCount(1), 2] {
            let (file, audio) = try samples(render(source(channels: channels)))
            XCTAssertEqual(file.processingFormat.channelCount, 2)
            XCTAssertEqual((file.fileFormat.settings[AVLinearPCMBitDepthKey] as? NSNumber)?.intValue, 24)
            let middle = audio[11_025..<33_075]
            let rms = sqrt(middle.reduce(0.0) { $0 + Double($1 * $1) } / Double(middle.count))
            // O mixer faz pan central de potência constante: mono perde 3 dB POR CANAL,
            // enquanto a soma da potência dos dois canais conserva a energia de entrada.
            let channelGain = channels == 1 ? 1 / sqrt(2.0) : 1
            let expected = 0.2 / sqrt(2.0) * pow(10.0, -1.5 / 20) * channelGain
            XCTAssertEqual(rms, expected, accuracy: 0.008, "Canais na fonte: \(channels)")
        }
    }

    func testBassAndReverbProduceFiniteUnclippedSamples() throws {
        let (_, audio) = try samples(render(source(frequency: 60, amplitude: 0.98),
                                           bass: 12, reverb: 50))
        XCTAssertTrue(audio.allSatisfy { $0.isFinite })
        XCTAssertLessThan(audio.map { abs($0) }.max() ?? 1, 0.99)
        XCTAssertGreaterThan(audio.map { abs($0) }.max() ?? 0, 0.05)
    }

    func testAACExportCanBeDecoded() throws {
        let (file, audio) = try samples(render(source(), format: .m4a))
        XCTAssertEqual(file.fileFormat.streamDescription.pointee.mFormatID, kAudioFormatMPEG4AAC)
        XCTAssertEqual(file.processingFormat.sampleRate, 44_100)
        XCTAssertEqual(file.processingFormat.channelCount, 2)
        XCTAssertGreaterThan(audio.count, 80_000)
        XCTAssertTrue(audio.allSatisfy { $0.isFinite })
    }

    @MainActor
    func testMP3ImportAndExport() throws {
        let url = folder.appendingPathComponent("test.mp3")
        try XCTUnwrap(Data(base64Encoded: mp3TestFixture)).write(to: url)
        let manager = AudioEngineManager()
        try manager.load(url: url)
        XCTAssertGreaterThan(manager.duration, 0.2)
        let (_, audio) = try samples(render(url))
        XCTAssertGreaterThan(audio.map { abs($0) }.max() ?? 0, 0.01)
    }

    /// Exploration-only smoke: no engine startup, files, UI, or export.
    func testExplorationVoiceOverlapChokeAndFastHitVariation() {
        var pool = PadVoiceAllocator(capacity: 16)
        var unique = Set<Int>()
        for i in 0..<16 {
            let allocation = pool.allocate(
                id: "kick", chokeGroup: nil, duration: 1,
                at: Double(i) * 0.012)!
            XCTAssertFalse(allocation.stoleVoice)
            unique.insert(allocation.voiceIndex)
        }
        XCTAssertEqual(unique.count, 16, "Fast kick retriggers must overlap")
        let overflow = pool.allocate(
            id: "kick", chokeGroup: nil, duration: 1, at: 0.20)!
        XCTAssertTrue(overflow.stoleVoice)
        XCTAssertEqual(overflow.interrupted.count, 1)
        XCTAssertEqual(overflow.interrupted.first?.voiceIndex, overflow.voiceIndex)
        XCTAssertEqual(overflow.interrupted.first?.previous.id, "kick")
        XCTAssertEqual(overflow.interrupted.first?.previous.began, 0)
        // A stolen voice retains its old lease for the 8ms release buffer.

        var hats = PadVoiceAllocator(capacity: 8)
        let kick = hats.allocate(
            id: "kick", chokeGroup: nil, duration: 1, at: 0)!
        let snare = hats.allocate(
            id: "snare", chokeGroup: nil, duration: 1, at: 0.002)!
        let clap = hats.allocate(
            id: "clap", chokeGroup: nil, duration: 1, at: 0.004)!
        let opened = hats.allocate(
            id: "open-hat", chokeGroup: "hat", duration: 0.54, at: 0.01)!
        let closed = hats.allocate(
            id: "closed-hat", chokeGroup: "hat", duration: 0.12, at: 0.04)!
        XCTAssertEqual(closed.chokeIndices, [opened.voiceIndex])
        XCTAssertEqual(closed.interrupted.count, 1)
        XCTAssertEqual(closed.interrupted.first?.previous.id, "open-hat")
        XCTAssertEqual(closed.interrupted.first?.previous.chokeGroup, "hat")
        XCTAssertNil(hats.leases[opened.voiceIndex].id)
        XCTAssertEqual(hats.leases[kick.voiceIndex].id, "kick")
        XCTAssertEqual(hats.leases[snare.voiceIndex].id, "snare")
        XCTAssertEqual(hats.leases[clap.voiceIndex].id, "clap")

        var dynamics = PadHitMicroVariation()
        let a = dynamics.velocity(for: "kick", requested: 0.75, at: 1)
        let b = dynamics.velocity(for: "kick", requested: 0.75, at: 1.06)
        let c = dynamics.velocity(for: "kick", requested: 0.75, at: 1.12)
        let reset = dynamics.velocity(for: "kick", requested: 0.75, at: 2)
        XCTAssertEqual(a, 0.75)
        XCTAssertNotEqual(a, b)
        XCTAssertNotEqual(b, c)
        XCTAssertEqual(reset, a)
        XCTAssertTrue([a, b, c].allSatisfy { (0.7...0.8).contains($0) })
    }


    func testExp2PadVelocityAndRecordingLatencyBounds() {
        XCTAssertEqual(PadExpressiveness.velocity(
            verticalZone: 0, base: 1, hitIndex: 0), 0.72, accuracy: 0.0001)
        XCTAssertEqual(PadExpressiveness.velocity(
            verticalZone: 1, base: 1, hitIndex: 0), 1, accuracy: 0.0001)
        XCTAssertEqual(PadExpressiveness.velocity(
            verticalZone: -10, base: 1, hitIndex: 0), 0.72, accuracy: 0.0001)
        XCTAssertEqual(PadExpressiveness.velocity(
            verticalZone: 10, base: 1, hitIndex: 0), 1, accuracy: 0.0001)
        XCTAssertEqual(PadExpressiveness.velocity(
            verticalZone: .nan, base: 0.85, hitIndex: 0), 0.85, accuracy: 0.0001)

        XCTAssertEqual(PadRecordingTiming.safeOutputLatency(-2), 0)
        XCTAssertEqual(PadRecordingTiming.safeOutputLatency(.nan), 0)
        XCTAssertEqual(PadRecordingTiming.safeOutputLatency(0.35), 0.2, accuracy: 0.000001)
        XCTAssertEqual(PadRecordingTiming.sourceTime(
            10, outputLatency: 0.05, speed: 1.25, duration: 30),
            9.9375, accuracy: 0.000001)
        XCTAssertEqual(PadRecordingTiming.sourceTime(
            10, outputLatency: 0.4, speed: 2, duration: 30),
            9.6, accuracy: 0.000001)
        XCTAssertEqual(PadRecordingTiming.sourceTime(
            0.05, outputLatency: 0.2, speed: 2, duration: 30), 0)
        XCTAssertEqual(PadRecordingTiming.sourceTime(
            40, outputLatency: 0, speed: 1, duration: 30), 30)
        XCTAssertEqual(PadRecordingTiming.sourceTime(
            .nan, outputLatency: 0.1, speed: 1, duration: 30), 0)
    }

}
