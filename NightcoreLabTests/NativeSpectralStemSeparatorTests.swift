import AVFoundation
import XCTest
@testable import NightcoreLab

final class NativeSpectralStemSeparatorTests: XCTestCase {
    func testFrequencyGuardsAndStereoEvidence() {
        XCTAssertEqual(NativeSpectralStemSeparator.vocalBandWeight(139), 0)
        XCTAssertEqual(NativeSpectralStemSeparator.vocalBandWeight(5501), 0)
        XCTAssertEqual(NativeSpectralStemSeparator.vocalBandWeight(1000), 1)
        XCTAssertEqual(NativeSpectralStemSeparator.vocalMask(
            hertz: 1000, leftReal: 1, leftImag: 0,
            rightReal: 1, rightImag: 0), 0.95, accuracy: 0.001)
        XCTAssertEqual(NativeSpectralStemSeparator.vocalMask(
            hertz: 80, leftReal: 1, leftImag: 0,
            rightReal: 1, rightImag: 0), 0)
        XCTAssertLessThan(NativeSpectralStemSeparator.vocalMask(
            hertz: 1000, leftReal: 1, leftImag: 0,
            rightReal: 0, rightImag: 1), 0.2)
        XCTAssertEqual(NativeVocalPitchReference.accuracy(
            sung: 440, reference: 440, pitchShift: 0), 1)
        XCTAssertEqual(NativeVocalPitchReference.accuracy(
            sung: 880, reference: 440, pitchShift: 0), 1)
        XCTAssertNil(NativeVocalPitchReference.accuracy(
            sung: 0, reference: 440, pitchShift: 0))
    }

    func testProducesAlignedLocalStemsAndReportsCompletion() async throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("native-stems-test-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = folder.appendingPathComponent("source.caf")
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2))
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatLinearPCM), AVSampleRateKey: 44_100,
            AVNumberOfChannelsKey: 2, AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true
        ]
        let frameCount = 8192
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format,
                                                    frameCapacity: AVAudioFrameCount(frameCount)))
        let channels = try XCTUnwrap(buffer.floatChannelData)
        buffer.frameLength = AVAudioFrameCount(frameCount)
        for frame in 0..<frameCount {
            let time = Double(frame) / 44_100
            let bass = Float(0.2 * sin(2 * Double.pi * 80 * time))
            let voice = Float(0.2 * sin(2 * Double.pi * 900 * time))
            let side = Float(0.1 * sin(2 * Double.pi * 1700 * time))
            channels[0][frame] = bass + voice + side
            channels[1][frame] = bass + voice - side
        }
        do {
            let writer = try AVAudioFile(forWriting: source, settings: settings,
                                          commonFormat: .pcmFormatFloat32, interleaved: false)
            try writer.write(from: buffer)
        }
        let progress = LockedPercentages()
        let asset = try await StemSplitterEngine.prepare(source: source, cacheFolder: folder) {
            progress.append($0)
        }
        let instrumental = try AVAudioFile(forReading: XCTUnwrap(asset.urls[.instrumental]))
        let vocals = try AVAudioFile(forReading: XCTUnwrap(asset.urls[.vocal]))
        XCTAssertEqual(instrumental.length, AVAudioFramePosition(frameCount))
        XCTAssertEqual(vocals.length, AVAudioFramePosition(frameCount))
        XCTAssertEqual(progress.values.first, 0)
        XCTAssertEqual(progress.values.last, 100)
        XCTAssertTrue(zip(progress.values, progress.values.dropFirst()).allSatisfy { $0 <= $1 })

        let instrumentalBuffer = try XCTUnwrap(AVAudioPCMBuffer(
            pcmFormat: instrumental.processingFormat, frameCapacity: AVAudioFrameCount(frameCount)))
        let vocalBuffer = try XCTUnwrap(AVAudioPCMBuffer(
            pcmFormat: vocals.processingFormat, frameCapacity: AVAudioFrameCount(frameCount)))
        try instrumental.read(into: instrumentalBuffer)
        try vocals.read(into: vocalBuffer)
        let bed = try XCTUnwrap(instrumentalBuffer.floatChannelData)
        let singing = try XCTUnwrap(vocalBuffer.floatChannelData)
        for frame in 512..<frameCount - 512 {
            XCTAssertEqual(bed[0][frame] + singing[0][frame], channels[0][frame], accuracy: 0.003)
            XCTAssertEqual(bed[1][frame] + singing[1][frame], channels[1][frame], accuracy: 0.003)
        }

        let cached = try await StemSplitterEngine.prepare(source: source, cacheFolder: folder)
        XCTAssertEqual(cached.urls[.instrumental], asset.urls[.instrumental])
        XCTAssertEqual(cached.urls[.vocal], asset.urls[.vocal])
        let pitchReference = try NativeVocalPitchReference.analyze(
            vocalsURL: XCTUnwrap(asset.vocalURL))
        XCTAssertTrue(pitchReference.hasVoicedSamples)
        XCTAssertEqual(pitchReference.frequency(at: 0.05) ?? 0, 900, accuracy: 40)

        try await MainActor.run {
            let audio = AudioEngineManager()
            try audio.load(url: source)
            audio.seek(to: 0.05)
            let revision = audio.playbackSourceRevision
            let position = audio.playbackTime
            try audio.setNativeStemPreview(.instrumental, asset: asset, expectedSource: source)
            XCTAssertEqual(audio.nativeStemPreview, .instrumental)
            XCTAssertEqual(audio.visualAnalysisURL, source)
            XCTAssertEqual(audio.playbackSourceRevision, revision)
            XCTAssertEqual(audio.playbackTime, position, accuracy: 0.001)
            try audio.setNativeStemPreview(.vocal, asset: asset, expectedSource: source)
            XCTAssertEqual(audio.nativeStemPreview, .vocal)
            try audio.setNativeStemPreview(nil, asset: asset, expectedSource: source)
            XCTAssertNil(audio.nativeStemPreview)
            XCTAssertEqual(audio.playbackTime, position, accuracy: 0.001)
        }
    }
}

private final class LockedPercentages: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [Int] = []
    func append(_ value: Int) { lock.lock(); stored.append(value); lock.unlock() }
    var values: [Int] { lock.lock(); defer { lock.unlock() }; return stored }
}
