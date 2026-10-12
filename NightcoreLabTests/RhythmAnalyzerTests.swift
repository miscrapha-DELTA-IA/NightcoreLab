import AVFoundation
import Foundation
import XCTest
@testable import NightcoreLab

final class RhythmAnalyzerTests: XCTestCase {
    // MARK: Synthetic audio (deterministic)

    private struct Noise {
        var state: UInt64
        mutating func next() -> Float {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Float(Double(state >> 11) / Double(1 << 53)) * 2 - 1
        }
    }

    /// Click track like the Python prototype: an accented low kick on the
    /// downbeat, softer low hits elsewhere, a short noise transient on every
    /// beat, ±10 ms jitter and a low noise floor. Returns samples and truth.
    private func clickTrack(bpm: Double, sampleRate: Double = 22_050,
                            seconds: Double = 20, downbeat: Int = 2,
                            seed: UInt64 = 1) -> (samples: [Float], beats: [Double]) {
        var noise = Noise(state: seed)
        let count = Int(seconds * sampleRate)
        var samples = (0..<count).map { _ in 0.003 * noise.next() }
        var beats: [Double] = []
        let period = 60 / bpm
        var time = 0.37
        var index = 0
        while time < seconds - 0.2 {
            let jittered = time + 0.010 * Double(noise.next())
            beats.append(jittered)
            let start = Int(jittered * sampleRate)
            let body = Int(0.12 * sampleRate)
            let accent = index % 4 == downbeat
            for k in 0..<body where start + k < count {
                let t: Double = Double(k) / sampleRate
                let envelope: Double = exp(-35 * t)
                let frequency: Double = accent ? 55 : 90
                let amplitude: Double = accent ? 0.8 : 0.35
                let tone: Double = amplitude * sin(2 * Double.pi * frequency * t)
                samples[start + k] += Float(envelope * tone)
            }
            for k in 0..<Int(0.006 * sampleRate) where start + k < count {
                samples[start + k] += 0.4 * noise.next()
            }
            time += period
            index += 1
        }
        return (samples, beats)
    }

    private func nearestError(_ grid: [RhythmAnalysisResult.BeatEvent],
                              _ truth: Double) -> Double {
        grid.map { abs($0.time - truth) }.min() ?? .infinity
    }

    private func median(_ values: [Double]) -> Double {
        let sorted = values.sorted()
        return sorted.isEmpty ? .infinity : sorted[sorted.count / 2]
    }

    // MARK: Accuracy

    /// v1 picked 120 for 124/128 BPM (hop quantization). v2 must not.
    func testTempoAndBeatPhaseAreAccurateOffTheVisualHop() throws {
        for bpm in [124.0, 128.0, 140.0] {
            let track = clickTrack(bpm: bpm, seed: UInt64(bpm))
            let result = try RhythmAnalyzer.analyze(channels: [track.samples],
                                                    sampleRate: 22_050)
            let top = try XCTUnwrap(result.bpmCandidates.first, "\(bpm)")
            XCTAssertEqual(top.bpm, bpm, accuracy: 1.0, "\(bpm)")
            XCTAssertGreaterThanOrEqual(result.confidence, 0.75, "\(bpm)")
            XCTAssertEqual(result.quality, .high, "\(bpm)")
            let interior = Array(track.beats.dropFirst(2).dropLast(2))
            let errors = interior.map { nearestError(result.beatGrid, $0) }
            XCTAssertLessThan(median(errors), 0.015, "\(bpm) median phase error")
            XCTAssertLessThan(errors.max() ?? 1, 0.05, "\(bpm) worst phase error")
            XCTAssertEqual(Double(result.beatGrid.count), Double(track.beats.count),
                           accuracy: 2, "\(bpm)")
            XCTAssertTrue(result.isValid(through: 20), "\(bpm)")
        }
    }

    func testDownbeatFollowsTheAccentedBeat() throws {
        for phase in 0..<4 {
            let track = clickTrack(bpm: 128, downbeat: phase, seed: UInt64(11 + phase))
            let result = try RhythmAnalyzer.analyze(channels: [track.samples],
                                                    sampleRate: 22_050)
            XCTAssertGreaterThan(result.downbeatConfidence, 0.3, "phase \(phase)")
            let accented = track.beats.enumerated()
                .filter { $0.offset % 4 == phase }.map(\.element)
                .dropFirst().dropLast()
            let hits = accented.filter { truth in
                result.beatGrid.min { abs($0.time - truth) < abs($1.time - truth) }?
                    .isDownbeat == true
            }
            XCTAssertGreaterThanOrEqual(Double(hits.count), Double(accented.count) * 0.8,
                                        "phase \(phase)")
        }
    }

    /// Octave ambiguity is real (87 vs 174 BPM): both hypotheses must survive.
    func testFastTempoKeepsTheOctaveHypothesis() throws {
        let track = clickTrack(bpm: 174, sampleRate: 16_000, seed: 174)
        let result = try RhythmAnalyzer.analyze(channels: [track.samples],
                                                sampleRate: 16_000)
        let top = try XCTUnwrap(result.bpmCandidates.first)
        XCTAssertTrue(abs(top.bpm - 174) <= 1.5 || abs(top.bpm - 87) <= 1.5, "\(top.bpm)")
        XCTAssertTrue(result.bpmCandidates.contains { abs($0.bpm - 174) <= 1.5 })
        XCTAssertTrue(result.bpmCandidates.contains { abs($0.bpm - 87) <= 1.5 })
    }

    // MARK: No invented rhythm

    func testNoiseAndSilenceDoNotProduceBeats() throws {
        var noise = Noise(state: 5)
        let hiss = (0..<(22_050 * 20)).map { _ in 0.2 * noise.next() }
        let noisy = try RhythmAnalyzer.analyze(channels: [hiss], sampleRate: 22_050)
        XCTAssertEqual(noisy.quality, .insufficient)
        XCTAssertTrue(noisy.beatGrid.isEmpty)
        XCTAssertTrue(noisy.isValid(through: 20))

        let silence = try RhythmAnalyzer.analyze(
            channels: [[Float](repeating: 0, count: 22_050 * 5)], sampleRate: 22_050)
        XCTAssertEqual(silence, RhythmAnalyzer.empty)
        XCTAssertEqual(silence.quality, .insufficient)
    }

    // MARK: Determinism and paths

    func testAnalysisIsDeterministicAndStereoSafe() throws {
        let track = clickTrack(bpm: 128, seed: 3)
        let first = try RhythmAnalyzer.analyze(channels: [track.samples], sampleRate: 22_050)
        let second = try RhythmAnalyzer.analyze(channels: [track.samples], sampleRate: 22_050)
        XCTAssertEqual(first, second)
        // Anti-phase stereo would cancel in a mono downmix; per-channel flux keeps it.
        let inverted = track.samples.map { -$0 }
        let stereo = try RhythmAnalyzer.analyze(channels: [track.samples, inverted],
                                                sampleRate: 22_050)
        XCTAssertEqual(try XCTUnwrap(stereo.bpmCandidates.first).bpm, 128, accuracy: 1)
        XCTAssertFalse(stereo.beatGrid.isEmpty)
    }

    func testFilePathMatchesInMemoryPathAndHonorsCoverage() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("rhythm-v2-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let track = clickTrack(bpm: 128, sampleRate: 16_000, seconds: 12, seed: 9)
        let url = folder.appendingPathComponent("click.caf")
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(
            pcmFormat: format, frameCapacity: AVAudioFrameCount(track.samples.count)))
        buffer.frameLength = AVAudioFrameCount(track.samples.count)
        let channel = try XCTUnwrap(buffer.floatChannelData?[0])
        for (index, sample) in track.samples.enumerated() { channel[index] = sample }
        do {
            let file = try AVAudioFile(forWriting: url, settings: format.settings)
            try file.write(from: buffer)
        }
        let fromFile = try RhythmAnalyzer.analyzeFile(at: url)
        let inMemory = try RhythmAnalyzer.analyze(channels: [track.samples], sampleRate: 16_000)
        XCTAssertEqual(fromFile, inMemory)

        let limited = try RhythmAnalyzer.analyzeFile(at: url, through: 6)
        XCTAssertTrue(limited.isValid(through: 6))
        XCTAssertTrue(limited.beatGrid.allSatisfy { $0.time <= 6 })
    }

    // MARK: Compatibility

    func testVersionOnePayloadStillDecodes() throws {
        let json = Data("""
        {"onsetEvents":[0.5],"bpmCandidates":[{"bpm":120,"confidence":0.8}],
         "beatGrid":[{"time":0.5,"index":0,"strength":1}],"confidence":0.8,
         "method":"spectral-flux-energy-interval-voting-v1","algorithmVersion":1,
         "quality":"high"}
        """.utf8)
        let legacy = try JSONDecoder().decode(RhythmAnalysisResult.self, from: json)
        XCTAssertEqual(legacy.algorithmVersion, 1)
        XCTAssertEqual(legacy.downbeatConfidence, 0)
        XCTAssertEqual(legacy.beatGrid.first?.isDownbeat, false)
        XCTAssertTrue(legacy.isValid(through: 1))
        XCTAssertNotEqual(legacy.algorithmVersion, RhythmAnalysisResult.algorithmVersion,
                          "The cache discards v1 rhythm and recomputes only rhythm")
    }

    // MARK: RhythmFrame

    private func syntheticRhythm() -> RhythmAnalysisResult {
        // 120 BPM from 1.0 s; downbeat on the second beat (index 1).
        // Explicit types: the Xcode 16 type checker times out on the literal form.
        let grid: [RhythmAnalysisResult.BeatEvent] = (0..<8).map { (index: Int) in
            let time: Double = 1 + 0.5 * Double(index)
            let strength: Float = index % 4 == 1 ? 1 : 0.5
            return RhythmAnalysisResult.BeatEvent(time: time, index: index,
                                                  strength: strength,
                                                  isDownbeat: index % 4 == 1)
        }
        return RhythmAnalysisResult(onsetEvents: grid.map { $0.time },
                                    bpmCandidates: [.init(bpm: 120, confidence: 0.9)],
                                    beatGrid: grid, confidence: 0.9,
                                    downbeatConfidence: 0.7)
    }

    func testRhythmFrameIsAPureFunctionOfTime() throws {
        let rhythm = syntheticRhythm()
        let mid = try XCTUnwrap(RhythmFrame.at(1.25, in: rhythm))
        XCTAssertEqual(mid.beatIndex, 0)
        XCTAssertEqual(mid.phase, 0.5, accuracy: 1e-12)
        XCTAssertEqual(mid.bpm, 120, accuracy: 1e-9)
        XCTAssertEqual(mid.barBeat, 3)
        XCTAssertEqual(try XCTUnwrap(mid.barPhase), 0.875, accuracy: 1e-12)
        XCTAssertEqual(mid.confidence, 0.9)

        let downbeat = try XCTUnwrap(RhythmFrame.at(1.5, in: rhythm))
        XCTAssertEqual(downbeat.beatIndex, 1)
        XCTAssertEqual(downbeat.phase, 0, accuracy: 1e-12)
        XCTAssertEqual(downbeat.barBeat, 0)
        XCTAssertEqual(downbeat.pulse(), 1, accuracy: 1e-12)
        XCTAssertEqual(downbeat.beatStrength, 1)
        XCTAssertLessThan(try XCTUnwrap(RhythmFrame.at(1.9, in: rhythm)).pulse(), 0.01)

        // Same answer regardless of query order or history.
        XCTAssertEqual(RhythmFrame.at(2.3, in: rhythm), RhythmFrame.at(2.3, in: rhythm))
    }

    func testRhythmFrameExtrapolatesOnlyOneInterval() throws {
        let rhythm = syntheticRhythm()
        let before = try XCTUnwrap(RhythmFrame.at(0.75, in: rhythm))
        XCTAssertEqual(before.beatIndex, -1)
        XCTAssertEqual(before.phase, 0.5, accuracy: 1e-12)
        XCTAssertEqual(before.beatStrength, 0)
        XCTAssertNil(RhythmFrame.at(0.2, in: rhythm))
        // Last tracked beat at 4.5 s.
        XCTAssertEqual(RhythmFrame.at(4.7, in: rhythm)?.beatIndex, 7)
        XCTAssertEqual(RhythmFrame.at(5.2, in: rhythm)?.beatIndex, 8)
        XCTAssertNil(RhythmFrame.at(5.6, in: rhythm))
        XCTAssertNil(RhythmFrame.at(.nan, in: rhythm))
        XCTAssertNil(RhythmFrame.at(1, in: RhythmAnalyzer.empty))
    }

    func testStaleRhythmRecomputesWithoutReanalyzingEnergy() async throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("rhythm-cache-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = try makeAudio(in: folder)
        let cacheURL = folder.appendingPathComponent("cache")
        let energyCalls = TestCounter()
        let rhythmCalls = TestCounter()
        let engine = MusicIntelligenceEngine(cache: MusicAnalysisCache(directory: cacheURL),
            analyze: { source in
                energyCalls.increment()
                return try AudioFeatureAnalyzer.analyzeFile(at: source)
            },
            extractRhythm: { url, timeline in
                rhythmCalls.increment()
                return try RhythmAnalyzer.analyzeFile(at: url, through: timeline.duration)
            })
        let first = try await engine.analysis(for: url)
        XCTAssertEqual(first.capabilities[.rhythm], .available)
        XCTAssertEqual(energyCalls.value, 1)
        XCTAssertEqual(rhythmCalls.value, 1)

        let cacheFile = try XCTUnwrap(FileManager.default.contentsOfDirectory(
            at: cacheURL, includingPropertiesForKeys: nil).first)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: cacheFile))
                                as? [String: Any])
        // Simulate a future algorithm version, distinct from the energy schema.
        json["rhythmAnalyzerVersion"] = RhythmAnalysisResult.algorithmVersion + 1
        var rhythm = try XCTUnwrap(json["rhythmAnalysis"] as? [String: Any])
        rhythm["algorithmVersion"] = RhythmAnalysisResult.algorithmVersion + 1
        json["rhythmAnalysis"] = rhythm
        try JSONSerialization.data(withJSONObject: json).write(to: cacheFile)

        let updated = try await engine.analysis(for: url)
        XCTAssertEqual(updated.energyTimeline, first.energyTimeline)
        XCTAssertEqual(updated.onsetEvents, first.onsetEvents)
        XCTAssertEqual(energyCalls.value, 1, "Rhythm invalidation must not rerun FFT")
        XCTAssertEqual(rhythmCalls.value, 2, "Only the rhythm capability is recalculated")
        XCTAssertEqual(updated.capabilities[.rhythm], .available)
    }

    func testRhythmFailureKeepsEnergyAndRetriesIndependently() async throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("rhythm-failure-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = try makeAudio(in: folder)
        let energyCalls = TestCounter()
        let cache = MusicAnalysisCache(directory: folder.appendingPathComponent("cache"))
        let failing = MusicIntelligenceEngine(cache: cache,
            analyze: { source in
                energyCalls.increment()
                return try AudioFeatureAnalyzer.analyzeFile(at: source)
            }, extractRhythm: { _, _ in throw FixtureError.unavailable })
        let partial = try await failing.analysis(for: url)
        XCTAssertEqual(partial.capabilities[.energy], .available)
        XCTAssertEqual(partial.capabilities[.rhythm], .failed("rhythm-analysis-failed"))
        XCTAssertNil(partial.rhythmAnalysis)
        let retry = MusicIntelligenceEngine(cache: cache, analyze: { source in
            energyCalls.increment()
            return try AudioFeatureAnalyzer.analyzeFile(at: source)
        })
        let recovered = try await retry.analysis(for: url)
        XCTAssertEqual(energyCalls.value, 1)
        XCTAssertEqual(recovered.capabilities[.rhythm], .available)
    }

    func testConcurrentSameAssetSharesEnergyAndRhythmWork() async throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("rhythm-share-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = try makeAudio(in: folder)
        let energyCalls = TestCounter()
        let rhythmCalls = TestCounter()
        let engine = MusicIntelligenceEngine(
            cache: MusicAnalysisCache(directory: folder.appendingPathComponent("cache")),
            analyze: { source in
                energyCalls.increment()
                Thread.sleep(forTimeInterval: 0.15)
                return try AudioFeatureAnalyzer.analyzeFile(at: source)
            },
            extractRhythm: { url, timeline in
                rhythmCalls.increment()
                return try RhythmAnalyzer.analyzeFile(at: url, through: timeline.duration)
            })
        async let first = engine.analysis(for: url)
        async let second = engine.analysis(for: url)
        let results = try await (first, second)
        XCTAssertEqual(results.0, results.1)
        XCTAssertEqual(energyCalls.value, 1)
        XCTAssertEqual(rhythmCalls.value, 1)
    }

    private func makeAudio(in folder: URL) throws -> URL {
        let url = folder.appendingPathComponent("fixture.caf")
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 8_000))
        buffer.frameLength = 8_000
        let samples = try XCTUnwrap(buffer.floatChannelData?[0])
        for index in 0..<8_000 {
            samples[index] = 0.4 * Float(sin(2 * .pi * 90 * Double(index) / 16_000))
        }
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
        return url
    }

    private enum FixtureError: Error { case unavailable }
}

private final class TestCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
    func increment() { lock.lock(); defer { lock.unlock() }; count += 1 }
}
