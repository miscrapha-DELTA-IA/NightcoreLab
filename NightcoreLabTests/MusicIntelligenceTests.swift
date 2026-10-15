import AVFoundation
import Foundation
import XCTest
@testable import NightcoreLab

final class MusicIntelligenceTests: XCTestCase {
    func testOctaveRuleAndFourBeatBarGrid() {
        let candidates = [
            RhythmAnalysisResult.BPMCandidate(bpm: 72, confidence: 0.9),
            RhythmAnalysisResult.BPMCandidate(bpm: 144, confidence: 0.74)
        ]
        XCTAssertEqual(SongDNA.resolveOctave(candidates), 144)
        let weak = [candidates[0], .init(bpm: 144, confidence: 0.70)]
        XCTAssertEqual(SongDNA.resolveOctave(weak), 72)
        let beats = (0..<12).map { index in
            RhythmAnalysisResult.BeatEvent(time: Double(index) * 0.5,
                index: index, strength: index % 4 == 1 ? 1 : 0.2)
        }
        let rhythm = RhythmAnalysisResult(onsetEvents: [0.5, 2.5, 4.5],
            bpmCandidates: candidates, beatGrid: beats, confidence: 0.9)
        XCTAssertEqual(SongDNA.barGrid(rhythm), [0.5, 2.5, 4.5])
    }

    private var directory: URL!
    private var cacheDirectory: URL { directory.appendingPathComponent("cache") }

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("music-intelligence-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: directory)
    }

    private func audio(_ name: String = "track", amplitude: Float = 0.4) throws -> URL {
        let url = directory.appendingPathComponent(name).appendingPathExtension("caf")
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4_000))
        buffer.frameLength = 4_000
        let samples = try XCTUnwrap(buffer.floatChannelData?[0])
        for index in 0..<4_000 {
            samples[index] = amplitude * Float(sin(2 * .pi * 90 * Double(index) / 16_000))
        }
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
        return url
    }

    private func service(counter: LockedCounter) -> MusicIntelligenceEngine {
        MusicIntelligenceEngine(cache: MusicAnalysisCache(directory: cacheDirectory), analyze: { url in
            counter.increment()
            return try AudioFeatureAnalyzer.analyzeFile(at: url)
        })
    }

    func testCacheMissThenPersistentHitAcrossServiceInstances() async throws {
        let url = try audio()
        let counter = LockedCounter()
        let first = try await service(counter: counter).analysis(for: url)
        XCTAssertEqual(counter.value, 1)
        let reopened = try await service(counter: counter).analysis(for: url)
        XCTAssertEqual(counter.value, 1, "A disk cache hit must skip decoding and FFT")
        XCTAssertEqual(first, reopened)
        XCTAssertTrue(reopened.coverage.isComplete)
        XCTAssertEqual(reopened.capabilities[.energy], .available)
    }

    func testDifferentAssetCannotReceiveAnotherTracksResult() async throws {
        let firstURL = try audio("first", amplitude: 0.1)
        let secondURL = try audio("second", amplitude: 0.8)
        let counter = LockedCounter()
        let engine = service(counter: counter)
        let first = try await engine.analysis(for: firstURL)
        let second = try await engine.analysis(for: secondURL)
        XCTAssertEqual(counter.value, 2)
        XCTAssertNotEqual(first.assetID, second.assetID)
        XCTAssertNotEqual(first.sourceRevision, second.sourceRevision)
        XCTAssertNotEqual(first.energyTimeline, second.energyTimeline)
        let bridge = AudioFeatureEngine(intelligence: engine)
        try await bridge.prepareAudio(at: firstURL)
        let wrong = await bridge.cachedTimeline(for: secondURL)
        XCTAssertNil(wrong)
    }

    func testSameURLSameSizeAndDateWithChangedContentInvalidatesCache() async throws {
        let url = try audio(amplitude: 0.1)
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let counter = LockedCounter()
        let engine = service(counter: counter)
        let original = try await engine.analysis(for: url)
        let bridge = AudioFeatureEngine(intelligence: engine)
        try await bridge.prepareAudio(at: url)
        _ = try audio(amplitude: 0.8)
        try FileManager.default.setAttributes([.modificationDate: attributes[.modificationDate]!],
                                              ofItemAtPath: url.path)
        let changedAttributes = try FileManager.default.attributesOfItem(atPath: url.path)
        XCTAssertEqual(attributes[.size] as? NSNumber, changedAttributes[.size] as? NSNumber)
        let changed = try await engine.analysis(for: url)
        XCTAssertEqual(counter.value, 2)
        XCTAssertEqual(original.assetID, changed.assetID)
        XCTAssertNotEqual(original.sourceRevision, changed.sourceRevision)
        XCTAssertNotEqual(original.energyTimeline, changed.energyTimeline)
        try await bridge.prepareAudio(at: url)
        let live = await bridge.cachedTimeline(for: url)
        XCTAssertEqual(live, changed.energyTimeline, "The bridge must also revalidate a repeated URL")
        XCTAssertEqual(counter.value, 2)
    }


    func testWarmDescriptorDetectsSameStampContentReplacement() async throws {
        let url = try audio(amplitude: 0.2)
        // Pin whole-second mtime BEFORE snapshotting so restoring it is exact
        // even on filesystems that round nanosecond timestamps.
        let fixedModified = Date(timeIntervalSince1970: 1_700_000_000)
        try FileManager.default.setAttributes([.modificationDate: fixedModified],
                                              ofItemAtPath: url.path)
        let identities = AssetIdentityCache()
        let original = try await identities.descriptor(for: url)
        let before = try AudioAssetDescriptor.FileStamp(url)
        _ = try audio(amplitude: 0.7)
        try FileManager.default.setAttributes([.modificationDate: fixedModified],
                                              ofItemAtPath: url.path)
        XCTAssertEqual(try AudioAssetDescriptor.FileStamp(url), before,
                       "Mutation fixture must preserve size, mtime and inode")
        let replacement = try await identities.descriptor(for: url)
        XCTAssertEqual(replacement.assetID, original.assetID)
        XCTAssertNotEqual(replacement.sourceRevision, original.sourceRevision)
        do {
            try await identities.validate(original)
            XCTFail("The old source revision must never be validated")
        } catch AudioAssetDescriptor.IdentityError.sourceChanged { }
    }

    func testCorruptedSourceWithUnchangedStampCannotReuseAnalysis() async throws {
        let url = try audio()
        let fixedModified = Date(timeIntervalSince1970: 1_700_000_000)
        try FileManager.default.setAttributes([.modificationDate: fixedModified],
                                              ofItemAtPath: url.path)
        let counter = LockedCounter()
        let engine = service(counter: counter)
        _ = try await engine.analysis(for: url)
        let stamp = try AudioAssetDescriptor.FileStamp(url)

        // Overwrite the CAF header in place: do not replace the inode or size.
        let handle = try FileHandle(forWritingTo: url)
        try handle.seek(toOffset: 0)
        try handle.write(contentsOf: Data(repeating: 0, count: 32))
        try handle.close()
        try FileManager.default.setAttributes([.modificationDate: fixedModified],
                                              ofItemAtPath: url.path)
        XCTAssertEqual(try AudioAssetDescriptor.FileStamp(url), stamp)
        do {
            _ = try await engine.analysis(for: url)
            XCTFail("An invalid audio header must not receive cached results")
        } catch { }
        XCTAssertEqual(counter.value, 1, "Corrupt replacement cannot decode or reuse prior FFT")
    }

    func testConcurrentRequestsShareOneAnalysis() async throws {
        let url = try audio()
        let counter = LockedCounter()
        let engine = MusicIntelligenceEngine(
            cache: MusicAnalysisCache(directory: cacheDirectory),
            analyze: { source in
                counter.increment()
                // Keep the worker active while other consumers join its URL job.
                Thread.sleep(forTimeInterval: 0.2)
                return try AudioFeatureAnalyzer.analyzeFile(at: source)
            })
        let results = try await withThrowingTaskGroup(of: MusicAnalysisResult.self) { group in
            for _ in 0..<8 {
                group.addTask { try await engine.analysis(for: url) }
            }
            var collected: [MusicAnalysisResult] = []
            for try await result in group { collected.append(result) }
            return collected
        }
        XCTAssertEqual(results.count, 8)
        XCTAssertEqual(counter.value, 1, "All consumers must share one decode/FFT job")
        XCTAssertTrue(results.allSatisfy { $0 == results[0] })
    }

    func testFailedTrackReplacementClearsPreviousVisualTimeline() async throws {
        let url = try audio()
        let bridge = AudioFeatureEngine(intelligence: service(counter: LockedCounter()))
        try await bridge.prepareAudio(at: url)
        do {
            try await bridge.prepareAudio(at: directory.appendingPathComponent("missing.caf"))
            XCTFail("Missing audio must fail identity resolution")
        } catch { }
        let old = await bridge.cachedTimeline(for: url)
        let current = await bridge.features(at: 0.1)
        XCTAssertNil(old)
        XCTAssertEqual(current, .silent)
    }

    func testFailureOfOnsetsPreservesEnergyAndRetriesWithoutFFT() async throws {
        let url = try audio()
        let counter = LockedCounter()
        let partialReceived = expectation(description: "Energy delivered before onsets")
        let engine = MusicIntelligenceEngine(
            cache: MusicAnalysisCache(directory: cacheDirectory),
            analyze: { url in
                counter.increment()
                return try AudioFeatureAnalyzer.analyzeFile(at: url)
            },
            extractOnsets: { _ in throw FixtureError.unavailable })
        let partial = try await engine.analysis(for: url) { result in
            if result.capabilities[.energy] == .available,
               result.capabilities[.onsets] == .pending {
                partialReceived.fulfill()
            }
        }
        await fulfillment(of: [partialReceived], timeout: 2)
        XCTAssertEqual(partial.capabilities[.energy], .available)
        XCTAssertEqual(partial.capabilities[.onsets], .failed("onset-analysis-failed"))
        XCTAssertNotNil(partial.energyTimeline)
        XCTAssertNil(partial.onsetEvents)
        XCTAssertTrue(partial.isTerminal)

        let recovered = try await service(counter: counter).analysis(for: url)
        XCTAssertEqual(counter.value, 1, "Retry must reuse the successful energy capability")
        XCTAssertEqual(recovered.energyTimeline, partial.energyTimeline)
        XCTAssertEqual(recovered.capabilities[.onsets], .available)
    }

    func testCorruptAndObsoleteCacheAreMisses() async throws {
        let url = try audio()
        let counter = LockedCounter()
        let engine = service(counter: counter)
        _ = try await engine.analysis(for: url)
        let entry = try XCTUnwrap(FileManager.default.contentsOfDirectory(
            at: cacheDirectory, includingPropertiesForKeys: nil).first)
        try Data("broken json".utf8).write(to: entry)
        _ = try await engine.analysis(for: url)
        XCTAssertEqual(counter.value, 2)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: entry))
                                as? [String: Any])
        json["schemaVersion"] = 999
        try JSONSerialization.data(withJSONObject: json).write(to: entry)
        _ = try await engine.analysis(for: url)
        XCTAssertEqual(counter.value, 3)
    }

    func testUnwritableCacheDoesNotDiscardAnalysis() async throws {
        let url = try audio()
        // Deterministic I/O failure, including on root/CI: parent is a regular file.
        try Data([1]).write(to: cacheDirectory)
        let result = try await service(counter: LockedCounter()).analysis(for: url)
        XCTAssertEqual(result.capabilities[.energy], .available)
        XCTAssertNotNil(result.energyTimeline)
    }

    func testSourceChangeDuringAnalysisIsNeverCachedOrReturned() async throws {
        let url = try audio()
        let engine = MusicIntelligenceEngine(cache: MusicAnalysisCache(directory: cacheDirectory),
            analyze: { source in
                let timeline = try AudioFeatureAnalyzer.analyzeFile(at: source)
                let handle = try FileHandle(forWritingTo: source)
                try handle.seekToEnd()
                try handle.write(contentsOf: Data([42]))
                try handle.close()
                return timeline
            })
        do {
            _ = try await engine.analysis(for: url)
            XCTFail("A changed source must not publish its old timeline")
        } catch AudioAssetDescriptor.IdentityError.sourceChanged {
            XCTAssertFalse(FileManager.default.fileExists(atPath: cacheDirectory.path))
        }
    }

    func testCoverageDoesNotClaimUnanalyzedTail() async throws {
        let url = try audio()
        let engine = MusicIntelligenceEngine(cache: MusicAnalysisCache(directory: cacheDirectory),
            analyze: { _ in
                AudioFeatureTimeline(points: [AudioFeaturePoint(time: 0.05, features: .silent)],
                                     duration: 0.1)
            })
        let result = try await engine.analysis(for: url)
        XCTAssertEqual(result.coverage.analyzedThrough, 0.1)
        XCTAssertEqual(result.coverage.sourceDuration, 0.25)
        XCTAssertFalse(result.coverage.isComplete)
        XCTAssertEqual(result.energyTimeline?.features(at: 0.2), .silent)
    }

    private enum FixtureError: Error { case unavailable }
}

/// Only used around injected synchronous DSP calls, never across an await.
private final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
    func increment() { lock.lock(); defer { lock.unlock() }; count += 1 }
}

/// Stage 25: exercise the two real versioned caches without decoding audio
/// during the live player handoff or inventing any section classification.
final class Stage25SongDNACacheTests: XCTestCase {
    func testCachedSongDNACombinesValidatedMusicAndExpression() async throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("songdna-v25-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let asset = AudioAssetDescriptor(
            url: folder.appendingPathComponent("track.caf"),
            assetID: "songdna-v25-fixture", sourceRevision: "content-r1",
            duration: 60,
            format: .init(sampleRate: 16_000, channelCount: 1, formatID: 1))
        let timeline = AudioFeatureTimeline(points: [
            AudioFeaturePoint(time: 0.1,
                features: AudioFeatures(bass: 0.7, mid: 0.5, treble: 0.5,
                                        energy: 0.8, beatDetected: true)),
            AudioFeaturePoint(time: 59.9,
                features: AudioFeatures(bass: 0.5, mid: 0.5, treble: 0.5,
                                        energy: 0.6, beatDetected: false))
        ], duration: 60)
        let rhythm = RhythmAnalysisResult(
            onsetEvents: [0.5, 1.0],
            bpmCandidates: [.init(bpm: 128, confidence: 0.90)],
            beatGrid: [
                .init(time: 0.5, index: 0, strength: 1, isDownbeat: true),
                .init(time: 1.0, index: 1, strength: 0.8)
            ], confidence: 0.90, downbeatConfidence: 0.8)
        let music = MusicAnalysisResult(
            asset: asset, energy: .available, onsets: .available,
            timeline: timeline, onsetEvents: [0.5, 1.0],
            rhythm: .available, rhythmAnalysis: rhythm)
        XCTAssertTrue(music.isValid(for: asset))
        let cache = MusicAnalysisCache(directory: folder.appendingPathComponent("music"))
        try await cache.store(music, for: asset)
        let provenance = ExpressionProvenance(
            method: "fixture", fingerprint: .init(algorithmVersion: 1),
            analyzedThrough: 60, confidence: 0.9)
        let expression = MusicExpressionResult(asset: asset,
            statuses: [.key: .available, .sections: .available, .moodHints: .available],
            key: KeyAnalysisResult(hypotheses: [
                KeyHypothesis(tonic: .a, scale: .minor, confidence: 0.9)
            ], provenance: provenance),
            sections: SectionAnalysisResult(sections: [
                MusicSection(startTime: 0, endTime: 15,
                             label: .intro, confidence: 0.95),
                MusicSection(startTime: 15, endTime: 30,
                             label: .verse, confidence: 0.95),
                MusicSection(startTime: 30, endTime: 40,
                             label: .preChorus, confidence: 0.95),
                MusicSection(startTime: 40, endTime: 50,
                             label: .chorus, confidence: 0.95),
                MusicSection(startTime: 50, endTime: 60,
                             label: .drop, confidence: 0.95)
            ], provenance: provenance),
            moodHints: MoodHintsResult(hints: [
                MoodHint(dimension: .spectralBrightness, normalizedValue: 0.82,
                         confidence: 0.88, evidence: "fixture")
            ], provenance: provenance))
        let expressions = ExpressionCache(directory: folder.appendingPathComponent("expressions"))
        try await expressions.store(expression, for: asset)
        let dna = await SongDNA.cached(for: asset, musicCache: cache,
                                       expressionCache: expressions)
        XCTAssertTrue(dna.isValid)
        XCTAssertEqual(dna.bpm, 128)
        XCTAssertEqual(dna.keyName, "a minor")
        XCTAssertEqual(dna.moodName, "spectralBrightness")
        XCTAssertEqual(dna.energy, 0.7, accuracy: 0.0001)
        XCTAssertEqual(dna.sections.count, 5)
        XCTAssertEqual(dna.section(at: 49.999)?.label, .chorus)
        XCTAssertEqual(dna.section(at: 50)?.label, .drop)
        let stale = AudioAssetDescriptor(
            url: asset.url, assetID: asset.assetID,
            sourceRevision: "content-r2", duration: 60, format: asset.format)
        let invalidated = await SongDNA.cached(
            for: stale, musicCache: cache, expressionCache: expressions)
        XCTAssertEqual(invalidated.bpm, 0)
        XCTAssertNil(invalidated.keyName)
        XCTAssertTrue(invalidated.sections.isEmpty)
    }
}
