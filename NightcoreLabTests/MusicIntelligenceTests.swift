import AVFoundation
import Foundation
import XCTest
@testable import NightcoreLab

final class MusicIntelligenceTests: XCTestCase {
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
