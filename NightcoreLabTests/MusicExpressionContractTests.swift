import Foundation
import XCTest
@testable import NightcoreLab

final class MusicExpressionContractTests: XCTestCase {
    private func asset(revision: String = "revision-1") -> AudioAssetDescriptor {
        AudioAssetDescriptor(
            url: URL(fileURLWithPath: "/fixture-expression.caf"),
            assetID: "expression-fixture", sourceRevision: revision,
            duration: 60, format: .init(sampleRate: 16_000, channelCount: 1, formatID: 1))
    }

    private func provenance(_ version: Int = 1, confidence: Double = 0.8)
        -> ExpressionProvenance {
        ExpressionProvenance(method: "test-fixture",
            fingerprint: ExpressionFingerprint(algorithmVersion: version),
            analyzedThrough: 60, confidence: confidence)
    }

    func testIndependentStatusAndEmptySnapshotRoundTrip() throws {
        let input = MusicExpressionResult(asset: asset(),
            statuses: [.key: .pending, .sections: .failed("not-enough-data")])
        XCTAssertTrue(input.isValid(for: asset()))
        XCTAssertFalse(input.isTerminal)
        XCTAssertEqual(input.capabilities[.melody], .notRequested)
        XCTAssertEqual(input.capabilities[.moodHints], .notRequested)
        let copy = try JSONDecoder().decode(MusicExpressionResult.self,
                                            from: JSONEncoder().encode(input))
        XCTAssertEqual(input, copy)
    }

    func testOptionalKeyHypothesesAndUncertaintySurviveSerialization() throws {
        let result = KeyAnalysisResult(hypotheses: [
            KeyHypothesis(tonic: .c, scale: .minor, confidence: 0.86),
            KeyHypothesis(tonic: .dSharp, scale: .major, confidence: 0.74)
        ], provenance: provenance())
        let snapshot = MusicExpressionResult(asset: asset(),
            statuses: [.key: .available], key: result)
        XCTAssertTrue(snapshot.isValid(for: asset()))
        XCTAssertEqual(result.key, .c)
        XCTAssertEqual(result.scale, .minor)
        XCTAssertEqual(result.confidence, 0.86)
        XCTAssertEqual(snapshot, try JSONDecoder().decode(MusicExpressionResult.self,
            from: JSONEncoder().encode(snapshot)))
        let silence = KeyAnalysisResult(hypotheses: [], provenance: provenance(confidence: 0))
        XCTAssertNil(silence.key, "No key hypothesis must not fabricate a tonic")
        XCTAssertTrue(silence.isValid(sourceDuration: 60))
    }

    func testSectionsMelodyAndMoodAreDataNotVisualInstructions() throws {
        let sections = SectionAnalysisResult(sections: [
            MusicSection(startTime: 0, endTime: 10, label: .intro, confidence: 0.9),
            MusicSection(startTime: 10, endTime: 25, label: .unknown, confidence: 0.3)
        ], provenance: provenance())
        let melody = MelodicFeatures(phrases: [
            MelodicPhrase(startTime: 2, endTime: 4, contour: [.ascending, .stable, .descending],
                          meanIntensity: 0.65, confidence: 0.5)
        ], provenance: provenance())
        let mood = MoodHintsResult(hints: [
            MoodHint(dimension: .spectralBrightness, normalizedValue: 0.7,
                     confidence: 0.6, evidence: "spectral-fixture")
        ], provenance: provenance())
        let snapshot = MusicExpressionResult(asset: asset(),
            statuses: [.sections: .available, .melody: .available, .moodHints: .available],
            sections: sections, melodicFeatures: melody, moodHints: mood)
        XCTAssertTrue(snapshot.isValid(for: asset()))
        XCTAssertEqual(snapshot.capabilities[.key], .notRequested)
        XCTAssertEqual(snapshot, try JSONDecoder().decode(MusicExpressionResult.self,
            from: JSONEncoder().encode(snapshot)))
    }

    func testInvalidPayloadOrCoverageCannotBePersistedAsValid() throws {
        let unavailable = KeyAnalysisResult(hypotheses: [
            KeyHypothesis(tonic: .c, scale: .major, confidence: .nan)
        ], provenance: provenance())
        let invalidKey = MusicExpressionResult(asset: asset(),
            statuses: [.key: .available], key: unavailable)
        XCTAssertFalse(invalidKey.isValid(for: asset()))
        let missing = MusicExpressionResult(asset: asset(), statuses: [.key: .available])
        XCTAssertFalse(missing.isValid(for: asset()))
        let overlapping = SectionAnalysisResult(sections: [
            MusicSection(startTime: 0, endTime: 30, label: .intro, confidence: 0.7),
            MusicSection(startTime: 20, endTime: 40, label: .verse, confidence: 0.7)
        ], provenance: provenance())
        XCTAssertFalse(overlapping.isValid(sourceDuration: 60))
        let invalidCoverage = ExpressionProvenance(method: "test",
            fingerprint: ExpressionFingerprint(algorithmVersion: 1),
            analyzedThrough: 61, confidence: 0.5)
        XCTAssertFalse(invalidCoverage.isValid(sourceDuration: 60))
    }

    func testDependenciesArePartOfAlgorithmFingerprint() {
        let first = ExpressionFingerprint(algorithmVersion: 2,
            dependencyVersions: ["rhythm": 1, "energy": 1])
        let second = ExpressionFingerprint(algorithmVersion: 2,
            dependencyVersions: ["rhythm": 2, "energy": 1])
        XCTAssertNotEqual(first, second)
        XCTAssertTrue(first.isValid)
        XCTAssertFalse(ExpressionFingerprint(algorithmVersion: 0).isValid)
        XCTAssertFalse(ExpressionFingerprint(algorithmVersion: 1,
            dependencyVersions: ["energy": 0]).isValid)
    }
}
