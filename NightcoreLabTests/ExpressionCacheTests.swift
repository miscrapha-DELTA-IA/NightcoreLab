import Foundation
import XCTest
@testable import NightcoreLab

final class ExpressionCacheTests: XCTestCase {
    private var folder: URL!
    private var expressionDirectory: URL { folder.appendingPathComponent("expression") }
    private var foundationDirectory: URL { folder.appendingPathComponent("foundation") }

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("expression-cache-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: folder)
    }

    private func asset(revision: String = "revision-1") -> AudioAssetDescriptor {
        AudioAssetDescriptor(url: folder.appendingPathComponent("fixture.caf"),
            assetID: "expression-asset", sourceRevision: revision, duration: 60,
            format: .init(sampleRate: 16_000, channelCount: 1, formatID: 1))
    }

    private func fingerprint(_ version: Int = 1,
                             dependencies: [String: Int] = [:]) -> ExpressionFingerprint {
        ExpressionFingerprint(algorithmVersion: version, dependencyVersions: dependencies)
    }

    private func metadata(_ version: Int = 1,
                          dependencies: [String: Int] = [:]) -> ExpressionProvenance {
        ExpressionProvenance(method: "fixture-only",
            fingerprint: fingerprint(version, dependencies: dependencies),
            analyzedThrough: 60, confidence: 0.8)
    }

    private func key(_ version: Int = 1,
                     dependencies: [String: Int] = [:]) -> KeyAnalysisResult {
        KeyAnalysisResult(hypotheses: [
            KeyHypothesis(tonic: .c, scale: .minor, confidence: 0.8)
        ], provenance: metadata(version, dependencies: dependencies))
    }

    private func sections() -> SectionAnalysisResult {
        SectionAnalysisResult(sections: [
            MusicSection(startTime: 0, endTime: 12, label: .intro, confidence: 0.8),
            MusicSection(startTime: 12, endTime: 60, label: .unknown, confidence: 0.5)
        ], provenance: metadata())
    }

    func testIndependentCachePersistenceAndReopen() async throws {
        let source = asset()
        let cache = ExpressionCache(directory: expressionDirectory)
        let input = MusicExpressionResult(asset: source,
            statuses: [.key: .available, .sections: .available],
            key: key(), sections: sections())
        try await cache.store(input, for: source)
        let reopened = ExpressionCache(directory: expressionDirectory)
        let result = await reopened.load(for: source,
            requiring: [.key: fingerprint(), .sections: fingerprint()])
        XCTAssertEqual(result.key, input.key)
        XCTAssertEqual(result.sections, input.sections)
        XCTAssertEqual(result.capabilities[.melody], .notRequested)
        XCTAssertTrue(result.isValid(for: source))
        XCTAssertTrue(result.isTerminal)
    }

    func testAlgorithmChangeInvalidatesOnlyKey() async throws {
        let source = asset()
        let cache = ExpressionCache(directory: expressionDirectory)
        let initial = MusicExpressionResult(asset: source,
            statuses: [.key: .available, .sections: .available],
            key: key(), sections: sections())
        try await cache.store(initial, for: source)

        let updated = await cache.load(for: source,
            requiring: [.key: fingerprint(2), .sections: fingerprint()])
        XCTAssertNil(updated.key)
        XCTAssertEqual(updated.capabilities[.key], .notRequested)
        XCTAssertEqual(updated.sections, initial.sections)
        XCTAssertEqual(updated.capabilities[.sections], .available)

        try await cache.store(MusicExpressionResult(asset: source,
            statuses: [.key: .available], key: key(2)), for: source)
        let recovered = await cache.load(for: source,
            requiring: [.key: fingerprint(2), .sections: fingerprint()])
        XCTAssertEqual(recovered.key, key(2))
        XCTAssertEqual(recovered.sections, initial.sections)
    }

    func testUpstreamDependencyVersionChangesOnlyRelevantCapability() async throws {
        let source = asset()
        let cache = ExpressionCache(directory: expressionDirectory)
        let derivedKey = key(1, dependencies: ["chroma": 1])
        try await cache.store(MusicExpressionResult(asset: source,
            statuses: [.key: .available, .sections: .available],
            key: derivedKey, sections: sections()), for: source)
        let result = await cache.load(for: source,
            requiring: [.key: fingerprint(1, dependencies: ["chroma": 2]),
                        .sections: fingerprint()])
        XCTAssertNil(result.key)
        XCTAssertEqual(result.sections, sections())
    }

    func testSourceRevisionReplacementInvalidatesAllExpression() async throws {
        let source = asset()
        let cache = ExpressionCache(directory: expressionDirectory)
        try await cache.store(MusicExpressionResult(asset: source,
            statuses: [.key: .available, .sections: .available],
            key: key(), sections: sections()), for: source)
        let replaced = asset(revision: "revision-2")
        let output = await cache.load(for: replaced,
            requiring: [.key: fingerprint(), .sections: fingerprint()])
        XCTAssertNil(output.key)
        XCTAssertNil(output.sections)
        XCTAssertEqual(output.capabilities[.key], .notRequested)
        XCTAssertEqual(output.capabilities[.sections], .notRequested)
    }

    func testCorruptKeyFileDoesNotDestroySections() async throws {
        let source = asset()
        let cache = ExpressionCache(directory: expressionDirectory)
        try await cache.store(MusicExpressionResult(asset: source,
            statuses: [.key: .available, .sections: .available],
            key: key(), sections: sections()), for: source)
        let hashed = AudioAssetDescriptor.digest(Data(source.assetID.utf8))
        let keyURL = expressionDirectory.appendingPathComponent(hashed + "-key.json")
        try Data("malformed JSON".utf8).write(to: keyURL)
        let output = await cache.load(for: source,
            requiring: [.key: fingerprint(), .sections: fingerprint()])
        XCTAssertNil(output.key)
        XCTAssertEqual(output.sections, sections())
        XCTAssertFalse(FileManager.default.fileExists(atPath: keyURL.path))
    }

    func testAvailablePartialCanPersistWhileAnotherCapabilityPending() async throws {
        let source = asset()
        let cache = ExpressionCache(directory: expressionDirectory)
        let partial = MusicExpressionResult(asset: source,
            statuses: [.key: .available, .sections: .pending], key: key())
        XCTAssertFalse(partial.isTerminal)
        try await cache.store(partial, for: source)
        let read = await cache.load(for: source,
            requiring: [.key: fingerprint(), .sections: fingerprint()])
        XCTAssertEqual(read.key, key())
        XCTAssertEqual(read.capabilities[.sections], .notRequested)
        // A failed attempt does not poison (or delete) a previously valid key.
        try await cache.store(MusicExpressionResult(asset: source,
            statuses: [.key: .failed("retry-later")]), for: source)
        let preserved = await cache.load(for: source, requiring: [.key: fingerprint()])
        XCTAssertEqual(preserved.key, key())
    }

    func testConcurrentIndependentStoresAndExplicitSelectiveInvalidation() async throws {
        let source = asset()
        let cache = ExpressionCache(directory: expressionDirectory)
        let resultKey = MusicExpressionResult(asset: source,
            statuses: [.key: .available], key: key())
        let resultSections = MusicExpressionResult(asset: source,
            statuses: [.sections: .available], sections: sections())
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { try await cache.store(resultKey, for: source) }
            group.addTask { try await cache.store(resultSections, for: source) }
            try await group.waitForAll()
        }
        let both = await cache.load(for: source,
            requiring: [.key: fingerprint(), .sections: fingerprint()])
        XCTAssertNotNil(both.key)
        XCTAssertNotNil(both.sections)
        await cache.invalidate([.key], for: source)
        let after = await cache.load(for: source,
            requiring: [.key: fingerprint(), .sections: fingerprint()])
        XCTAssertNil(after.key)
        XCTAssertNotNil(after.sections)
    }

    func testFoundationEnergyAndRhythmDiskEntriesStayUntouched() async throws {
        let source = asset()
        let foundation = MusicAnalysisCache(directory: foundationDirectory)
        let timeline = AudioFeatureTimeline(points: [
            AudioFeaturePoint(time: 0.1, features: AudioFeatures(energy: 0.5))
        ], duration: 1)
        let analysis = MusicAnalysisResult(asset: source, energy: .available,
            onsets: .available, timeline: timeline, onsetEvents: [])
        try await foundation.store(analysis, for: source)
        let foundationFilesBefore = try FileManager.default.contentsOfDirectory(
            at: foundationDirectory, includingPropertiesForKeys: nil).map(\.lastPathComponent)
        let expression = ExpressionCache(directory: expressionDirectory)
        try await expression.store(MusicExpressionResult(asset: source,
            statuses: [.key: .available], key: key()), for: source)
        await expression.invalidate([.key], for: source)
        let preserved = await foundation.load(for: source)
        XCTAssertEqual(preserved, analysis)
        let foundationFilesAfter = try FileManager.default.contentsOfDirectory(
            at: foundationDirectory, includingPropertiesForKeys: nil).map(\.lastPathComponent)
        XCTAssertEqual(foundationFilesBefore, foundationFilesAfter)
    }

    func testInvalidSnapshotIsRejected() async throws {
        let source = asset()
        let cache = ExpressionCache(directory: expressionDirectory)
        let invalid = MusicExpressionResult(asset: source, statuses: [.key: .available])
        do {
            try await cache.store(invalid, for: source)
            XCTFail("Available capability requires a valid payload")
        } catch ExpressionCache.CacheError.invalidResult { }
        XCTAssertFalse(FileManager.default.fileExists(atPath: expressionDirectory.path))
    }
}
