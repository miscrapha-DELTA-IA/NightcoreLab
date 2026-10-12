import AVFoundation
import Foundation
import XCTest
@testable import NightcoreLab

final class AudioVisualMapperTests: XCTestCase {
    private func preset(reaction: CreativePreset.AudioReaction = .responsive,
                        intensity: Double = 1,
                        motion: Double = 0.8) -> CreativePreset {
        CreativePreset(
            id: "reactive", name: "Reactive", theme: .cyber,
            typographyStyle: .neon,
            visualStyle: VisualPreset(
                background: .marble,
                shaderParameters: .init(timeScale: 0.5, distortion: 1, glow: 1),
                intensity: intensity, motion: motion),
            audioReaction: reaction
        )
    }

    func testZeroBassAndSilenceProduceMinimumSafeResponse() {
        let output = AudioVisualMapper.map(.silent, preset: preset())
        XCTAssertEqual(output, .neutral)
        XCTAssertEqual(output.intensity, 0)
        XCTAssertEqual(output.scale, 1)
        XCTAssertEqual(output.emissionRate, 0)
        XCTAssertEqual(output.wordAnimationIntensity, 0)
    }

    func testMaximumBassReachesMaximumIntensity() {
        let maximum = AudioFeatures(bass: 1, mid: 0, treble: 0, energy: 0)
        let output = AudioVisualMapper.map(maximum, preset: preset())
        XCTAssertEqual(output.intensity, 1)
        XCTAssertEqual(output.scale, 1.06, accuracy: 0.000_001)
        XCTAssertGreaterThan(output.glow, 0)
        XCTAssertGreaterThan(output.distortionAmount, 0)
    }

    func testReactionOffKeepsActualPlayerVisuallyUnchanged() {
        let strong = AudioFeatures(bass: 1, mid: 1, treble: 1, energy: 1, beatDetected: true)
        XCTAssertEqual(AudioVisualMapper.map(strong, preset: preset(reaction: .off)), .neutral)
    }

    func testLowEnergyProducesLessMotionAndAllOutputsRemainBounded() {
        let low = AudioVisualMapper.map(
            AudioFeatures(bass: 0.2, mid: 0.3, treble: 0.4, energy: 0.1),
            preset: preset())
        let high = AudioVisualMapper.map(
            AudioFeatures(bass: 0.8, mid: 0.7, treble: 0.8, energy: 1),
            preset: preset())
        XCTAssertLessThan(low.motion, high.motion)
        XCTAssertLessThan(low.intensity, high.intensity)
        XCTAssertTrue((1...1.06).contains(high.scale))
        for field in [high.glow, high.distortion, high.intensity, high.motion,
                      high.wordAnimationIntensity, high.distortionAmount, high.emissionRate] {
            XCTAssertTrue((0...1).contains(field))
        }
        let subtle = AudioVisualMapper.map(
            AudioFeatures(bass: 1, mid: 1, treble: 1, energy: 1),
            preset: preset(reaction: .subtle))
        XCTAssertLessThan(subtle.intensity, high.intensity)
    }

    func testThrottlingLowPowerSeekAndNoDuplicatePublications() {
        var throttle = VisualResponseThrottle()
        XCTAssertTrue(throttle.shouldEmit(at: 0, lowPower: false))
        XCTAssertFalse(throttle.shouldEmit(at: 0.02, lowPower: false))
        XCTAssertTrue(throttle.shouldEmit(at: 0.09, lowPower: false))
        XCTAssertFalse(throttle.shouldEmit(at: 0.17, lowPower: true))
        XCTAssertTrue(throttle.shouldEmit(at: 0.27, lowPower: true))
        XCTAssertTrue(throttle.shouldEmit(at: 0.01, lowPower: true),
                      "A backward seek should reset the time gate")
        throttle.reset()
        XCTAssertTrue(throttle.shouldEmit(at: 0.02, lowPower: false))
        XCTAssertFalse(throttle.shouldEmit(at: .nan, lowPower: false))
    }

    func testFeatureEnvelopeSeparatesBassAndTrebleDeterministically() {
        let sampleRate = 16_000.0
        func tone(_ frequency: Double) -> [Float] {
            (0..<16_000).map { n in
                Float(0.45 * sin(2 * .pi * frequency * Double(n) / sampleRate))
            }
        }
        let bass = AudioFeatureAnalyzer.analyze(samples: tone(85), sampleRate: sampleRate)
        let treble = AudioFeatureAnalyzer.analyze(samples: tone(4_000), sampleRate: sampleRate)
        let low = bass.features(at: 0.5)
        let high = treble.features(at: 0.5)
        XCTAssertGreaterThan(low.bass, high.bass)
        XCTAssertGreaterThan(high.treble, low.treble)
        XCTAssertGreaterThan(low.energy, 0.1)
        XCTAssertEqual(bass.points.count, AudioFeatureAnalyzer.analyze(
            samples: tone(85), sampleRate: sampleRate).points.count)
        XCTAssertEqual(bass.duration, 1, accuracy: 0.0001)
        XCTAssertEqual(bass.features(at: -1), .silent)
        XCTAssertEqual(bass.features(at: 2), .silent)
    }

    func testOnsetIsEventNotBPMGuess() {
        let sampleRate = 16_000.0
        let quiet = [Float](repeating: 0, count: 16_000)
        let strong = (0..<16_000).map {
            Float(0.55 * sin(2 * .pi * 90 * Double($0) / sampleRate))
        }
        let timeline = AudioFeatureAnalyzer.analyze(samples: quiet + strong,
                                                    sampleRate: sampleRate)
        XCTAssertEqual(timeline.features(at: 0.5), .silent)
        XCTAssertTrue(timeline.points.contains { $0.features.beatDetected })
    }

    func testInvalidInputStaysSilent() {
        XCTAssertEqual(AudioFeatureAnalyzer.analyze(samples: [], sampleRate: 48_000).points.count, 0)
        XCTAssertEqual(AudioFeatureAnalyzer.analyze(samples: [1, 2], sampleRate: .nan).duration, 0)
    }

    func testReadOnlyFileAnalysisAndActorResponse() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("creative-feature-fixture-\(UUID().uuidString).caf")
        defer { try? FileManager.default.removeItem(at: url) }
        let format = try XCTUnwrap(AVAudioFormat(
            standardFormatWithSampleRate: 16_000, channels: 1))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16_000))
        buffer.frameLength = 16_000
        let channel = try XCTUnwrap(buffer.floatChannelData?[0])
        for n in 0..<16_000 {
            channel[n] = Float(0.5 * sin(2 * .pi * 90 * Double(n) / 16_000))
        }
        do {
            let file = try AVAudioFile(forWriting: url, settings: format.settings,
                                       commonFormat: .pcmFormatFloat32, interleaved: false)
            try file.write(from: buffer)
        }

        let actor = AudioFeatureEngine()
        try await actor.prepareAudio(at: url)
        let envelope = await actor.features(at: 0.5)
        XCTAssertGreaterThan(envelope.bass, 0)
        XCTAssertGreaterThan(envelope.energy, 0)

        let first = await actor.visualResponse(
            at: 0.5, preset: preset(), isPlaying: true, lowPower: false)
        XCTAssertNotNil(first)
        XCTAssertGreaterThan(first?.intensity ?? 0, 0)
        let duplicate = await actor.visualResponse(
            at: 0.52, preset: preset(), isPlaying: true, lowPower: false)
        XCTAssertNil(duplicate)

        let paused = await actor.visualResponse(
            at: 0.8, preset: preset(), isPlaying: false, lowPower: false)
        XCTAssertEqual(paused, .neutral)
        await actor.reset()
        let cleared = await actor.features(at: 0.5)
        XCTAssertEqual(cleared, .silent)
    }
}
