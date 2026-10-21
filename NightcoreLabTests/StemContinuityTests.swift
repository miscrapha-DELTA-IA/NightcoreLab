import AVFoundation
import XCTest
@testable import NightcoreLab

final class StemContinuityTests: XCTestCase {
    func testJournalOwnsSourceAndCanRestoreAfterOriginalIsRemoved() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let original = root.appendingPathComponent("input.m4a")
        let bytes = Data([1, 4, 9, 16]); try bytes.write(to: original)
        let jobs = root.appendingPathComponent("jobs", isDirectory: true)
        let saved = try StemJobJournal.create(source: original, title: "First song", cloud: true, preview: nil, in: jobs)
        try FileManager.default.removeItem(at: original)
        let restored = try XCTUnwrap(StemJobJournal.load(in: jobs))
        XCTAssertEqual(restored.id, saved.id)
        XCTAssertEqual(restored.originalSource, original)
        XCTAssertEqual(try Data(contentsOf: restored.source), bytes)
        XCTAssertTrue(restored.automaticResume)
        restored.remove(in: jobs)
        XCTAssertNil(StemJobJournal.load(in: jobs))
        XCTAssertFalse(FileManager.default.fileExists(atPath: restored.source.path))
    }

    func testCheckpointRestoresExactFloatSamplesAndRejectsPartialOrCorruptData() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("segment.pcm")
        let samples: [Float] = [0, 0.123456, -0.75, 1.4, -2.1]
        try StemSegmentCheckpoint.save(samples, to: file)
        XCTAssertEqual(StemSegmentCheckpoint.load(file, count: samples.count), samples)
        XCTAssertNil(StemSegmentCheckpoint.load(file, count: samples.count + 1))
        var bytes = try Data(contentsOf: file); bytes[0] ^= 1
        try bytes.write(to: file)
        XCTAssertNil(StemSegmentCheckpoint.load(file, count: samples.count))
    }

    func testBackgroundPauseCanResumeWithoutBecomingCancellation() async throws {
        let lifecycle = StemWorkLifecycle()
        lifecycle.setBackgrounded(true)
        XCTAssertThrowsError(try lifecycle.check()) { XCTAssertTrue($0 is StemWorkLifecycle.Paused) }
        let resumed = Task { try await lifecycle.waitForForeground(); return true }
        lifecycle.setBackgrounded(false)
        let didResume = try await resumed.value
        XCTAssertTrue(didResume)
        lifecycle.setBackgrounded(true)
        let cancelled = Task { try await lifecycle.waitForForeground() }
        cancelled.cancel()
        do { try await cancelled.value; XCTFail("Explicit cancellation must still work while paused") }
        catch is CancellationError { }
    }
}
