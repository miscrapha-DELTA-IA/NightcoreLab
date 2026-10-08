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
}
