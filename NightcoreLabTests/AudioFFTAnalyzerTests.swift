import Accelerate
import AVFoundation
import Foundation
import XCTest
@testable import NightcoreLab

final class AudioFFTAnalyzerTests: XCTestCase {
    private func tone(frequency: Double, sampleRate: Double,
                      duration: Double = 1.0, amplitude: Double = 0.38) -> [Float] {
        (0..<Int(sampleRate * duration)).map {
            Float(amplitude * sin(2 * .pi * frequency * Double($0) / sampleRate))
        }
    }

    func testFFTWindowSizeIsPowerOfTwoAndBounded() {
        for rate in [8_000.0, 16_000, 44_100, 48_000, 96_000, 192_000] {
            let count = AudioFFTSpectrum.windowSize(sampleRate: rate)
            XCTAssertTrue((2048...8192).contains(count))
            XCTAssertEqual(count & (count - 1), 0)
            XCTAssertNotNil(AudioFFTSpectrum(sampleRate: rate))
        }
        XCTAssertNil(AudioFFTSpectrum(sampleRate: .nan))
        XCTAssertNil(AudioFFTSpectrum(sampleRate: 0))
    }

    func testBassMidTreblePureTonesChooseRightFrequencyBand() {
        for sampleRate in [16_000.0, 44_100, 48_000] {
            let bass = AudioFeatureAnalyzer.analyze(
                samples: tone(frequency: 85, sampleRate: sampleRate),
                sampleRate: sampleRate).features(at: 0.5)
            let mid = AudioFeatureAnalyzer.analyze(
                samples: tone(frequency: 1_000, sampleRate: sampleRate),
                sampleRate: sampleRate).features(at: 0.5)
            let high = AudioFeatureAnalyzer.analyze(
                samples: tone(frequency: 5_000, sampleRate: sampleRate),
                sampleRate: sampleRate).features(at: 0.5)
            XCTAssertGreaterThan(bass.bass, bass.mid * 2,
                                 "Bass leaking into mid at \(sampleRate) Hz")
            XCTAssertGreaterThan(mid.mid, mid.bass * 2,
                                 "Mid leaking into bass at \(sampleRate) Hz")
            XCTAssertGreaterThan(mid.mid, mid.treble * 2)
            XCTAssertGreaterThan(high.treble, high.mid * 2,
                                 "Treble leaking into mid at \(sampleRate) Hz")
            XCTAssertGreaterThan(bass.energy, 0.1)
            XCTAssertGreaterThan(mid.energy, 0.1)
            XCTAssertGreaterThan(high.energy, 0.1)
        }
    }

    func testSilenceProducesNoSpectrumOrBeats() {
        let timeline = AudioFeatureAnalyzer.analyze(
            samples: [Float](repeating: 0, count: 48_000), sampleRate: 48_000)
        XCTAssertEqual(timeline.duration, 1, accuracy: 0.00001)
        XCTAssertFalse(timeline.points.isEmpty)
        for point in timeline.points {
            XCTAssertEqual(point.features, .silent)
        }
    }

    func testFFTWorksWithPartialFinalWindowWithoutNaN() {
        let samples = tone(frequency: 100, sampleRate: 44_100, duration: 0.23)
        let timeline = AudioFeatureAnalyzer.analyze(samples: samples, sampleRate: 44_100)
        XCTAssertEqual(timeline.duration, 0.23, accuracy: 0.0001)
        XCTAssertFalse(timeline.points.isEmpty)
        for point in timeline.points {
            XCTAssertTrue(point.features.bass.isFinite)
            XCTAssertTrue(point.features.mid.isFinite)
            XCTAssertTrue(point.features.treble.isFinite)
            XCTAssertTrue((0...1).contains(point.features.energy))
        }
    }

    func testStereoAntiphaseDoesNotCancelSpectralBassOrEnergy() throws {
        let sampleRate = 48_000.0
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("fft-stereo-\(UUID().uuidString).caf")
        defer { try? FileManager.default.removeItem(at: url) }
        let format = try XCTUnwrap(AVAudioFormat(
            standardFormatWithSampleRate: sampleRate, channels: 2))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(
            pcmFormat: format, frameCapacity: AVAudioFrameCount(sampleRate)))
        buffer.frameLength = AVAudioFrameCount(sampleRate)
        let data = try XCTUnwrap(buffer.floatChannelData)
        for index in 0..<Int(sampleRate) {
            let value = Float(0.40 * sin(2 * .pi * 90 * Double(index) / sampleRate))
            data[0][index] = value
            data[1][index] = -value
        }
        do {
            let file = try AVAudioFile(
                forWriting: url, settings: format.settings,
                commonFormat: .pcmFormatFloat32, interleaved: false)
            try file.write(from: buffer)
        }
        let timeline = try AudioFeatureAnalyzer.analyzeFile(at: url)
        let features = timeline.features(at: 0.5)
        XCTAssertGreaterThan(features.bass, 0.15)
        XCTAssertGreaterThan(features.energy, 0.2)
        XCTAssertGreaterThan(features.bass, features.mid * 2)
        XCTAssertEqual(timeline.duration, 1, accuracy: 0.00001)
    }

    func testOptInEngineStillHasSilentDefaultAndCanResetAfterFFT() async throws {
        let engine = AudioFeatureEngine()
        let initial = await engine.snapshot()
        XCTAssertEqual(initial, .silent)
        let accepted = await engine.accept(AudioFeatureFrame(
            bassLevel: 0.8, midLevel: 0.4, trebleLevel: 0.1,
            rmsLevel: 0.5))
        XCTAssertEqual(accepted.bass, 0.8)
        await engine.reset()
        let final = await engine.snapshot()
        XCTAssertEqual(final, .silent)
    }
}
