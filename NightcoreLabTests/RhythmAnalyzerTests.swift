import AVFoundation
import Foundation
import XCTest
@testable import NightcoreLab

final class RhythmAnalyzerTests: XCTestCase {
    private func envelope(intervals: [Int], step: Double = 1.0 / 12) -> AudioFeatureTimeline {
        var attacks = Set<Int>()
        var cursor = 3
        attacks.insert(cursor)
        for interval in intervals {
            cursor += interval
            attacks.insert(cursor)
        }
        let frames = cursor + 18
        let points = (0..<frames).map { index in
            let hit = attacks.contains(index)
            return AudioFeaturePoint(time: Double(index) * step,
                features: AudioFeatures(
                    bass: hit ? 0.9 : 0.01,
                    mid: hit ? 0.8 : 0.01,
                    treble: hit ? 0.7 : 0.01,
                    energy: hit ? 0.85 : 0.02,
                    beatDetected: hit))
        }
        return AudioFeatureTimeline(points: points, duration: Double(frames) * step)
    }

    func testSilenceProducesNoFalseOnsetsCandidatesOrGrid() throws {
        let timeline = AudioFeatureTimeline(
            points: (0..<240).map {
                AudioFeaturePoint(time: Double($0) / 12, features: .silent)
            }, duration: 20)
        let result = try RhythmAnalyzer.analyze(timeline: timeline)
        XCTAssertEqual(result.onsetEvents, [])
        XCTAssertEqual(result.bpmCandidates, [])
        XCTAssertEqual(result.beatGrid, [])
        XCTAssertEqual(result.confidence, 0)
        XCTAssertEqual(result.quality, .insufficient)
        XCTAssertTrue(result.isValid(through: timeline.duration))
    }

    func testPeriodicSignalKeepsEightyAndOneSixtyBPMHypotheses() throws {
        let timeline = envelope(intervals: Array(repeating: 9, count: 24))
        let result = try RhythmAnalyzer.analyze(timeline: timeline)
        XCTAssertGreaterThanOrEqual(result.onsetEvents.count, 20)
        XCTAssertTrue(result.bpmCandidates.contains { abs($0.bpm - 80) <= 3 },
                      "80 BPM should be a plausible pulse")
        XCTAssertTrue(result.bpmCandidates.contains { abs($0.bpm - 160) <= 3 },
                      "160 BPM should remain an octave-related alternative")
        XCTAssertGreaterThan(result.confidence, 0.5)
        XCTAssertFalse(result.beatGrid.isEmpty)
        XCTAssertTrue(result.beatGrid.allSatisfy { $0.time <= timeline.duration })
        XCTAssertTrue(result.isValid(through: timeline.duration))
    }

    func testTempoChangeDoesNotExtrapolateOrCrash() throws {
        let timeline = envelope(intervals: Array(repeating: 8, count: 14)
                                + Array(repeating: 6, count: 14))
        let result = try RhythmAnalyzer.analyze(timeline: timeline)
        XCTAssertGreaterThan(result.onsetEvents.count, 12)
        XCTAssertTrue(result.confidence.isFinite)
        XCTAssertTrue(result.bpmCandidates.allSatisfy { $0.bpm.isFinite })
        XCTAssertTrue(result.beatGrid.allSatisfy { $0.time >= 0 && $0.time <= timeline.duration })
        XCTAssertTrue(result.isValid(through: timeline.duration))
    }

    func testWeakPulseTrainNeverForgesTempo() throws {
        let timeline = AudioFeatureTimeline(
            points: (0..<200).map { index in
                AudioFeaturePoint(time: Double(index) / 12,
                                  features: AudioFeatures(energy: 0.01))
            }, duration: 200.0 / 12)
        let result = try RhythmAnalyzer.analyze(timeline: timeline)
        XCTAssertTrue(result.onsetEvents.isEmpty)
        XCTAssertTrue(result.beatGrid.isEmpty)
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
            extractRhythm: { timeline in
                rhythmCalls.increment()
                return try RhythmAnalyzer.analyze(timeline: timeline)
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
            }, extractRhythm: { _ in throw FixtureError.unavailable })
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
            extractRhythm: { timeline in
                rhythmCalls.increment()
                return try RhythmAnalyzer.analyze(timeline: timeline)
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
