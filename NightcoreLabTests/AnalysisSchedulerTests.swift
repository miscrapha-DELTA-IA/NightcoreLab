import Foundation
import XCTest
@testable import NightcoreLab

final class AnalysisSchedulerTests: XCTestCase {
    private func fixture() -> MusicAnalysisResult {
        MusicAnalysisResult(asset: AudioAssetDescriptor(
            url: URL(fileURLWithPath: "/fixture.caf"), assetID: "fixture", sourceRevision: "revision",
            duration: 1, format: .init(sampleRate: 16_000, channelCount: 1, formatID: 1)))
    }

    func testSharedWorkSurvivesOneConsumersCancellation() async throws {
        let scheduler = AnalysisScheduler()
        let gate = AnalysisTestGate()
        let started = expectation(description: "Worker started")
        let joined = expectation(description: "Second consumer received shared snapshot")
        let result = fixture()
        let first = Task {
            try await scheduler.run(key: "same") { emit in
                await emit(result)
                started.fulfill()
                await gate.wait()
                try Task.checkCancellation()
                return result
            }
        }
        await fulfillment(of: [started], timeout: 2)
        let second = Task {
            try await scheduler.run(key: "same", onUpdate: { _ in joined.fulfill() }) { _ in
                XCTFail("Shared work must not execute twice")
                return result
            }
        }
        await fulfillment(of: [joined], timeout: 2)
        first.cancel()
        do { _ = try await first.value; XCTFail("Consumer must be cancelled promptly") }
        catch is CancellationError { }
        await gate.open()
        let surviving = try await second.value
        XCTAssertEqual(surviving, result)
    }

    func testLastConsumerCancelsWorkerAndNextRequestCanRun() async throws {
        let scheduler = AnalysisScheduler()
        let gate = AnalysisTestGate()
        let started = expectation(description: "Worker started")
        let cancelled = expectation(description: "Worker cancelled")
        let result = fixture()
        let consumer = Task {
            try await scheduler.run(key: "same") { _ in
                await withTaskCancellationHandler {
                    started.fulfill()
                    await gate.wait()
                } onCancel: {
                    cancelled.fulfill()
                    Task { await gate.open() }
                }
                try Task.checkCancellation()
                return result
            }
        }
        await fulfillment(of: [started], timeout: 2)
        consumer.cancel()
        do { _ = try await consumer.value; XCTFail("Expected cancellation") }
        catch is CancellationError { }
        await fulfillment(of: [cancelled], timeout: 2)
        let next = try await scheduler.run(key: "same") { _ in result }
        XCTAssertEqual(next, result)
    }

    func testCancelledQueuedConsumerNeverStartsItsWork() async throws {
        let scheduler = AnalysisScheduler(maxConcurrentAnalyses: 1)
        let gate = AnalysisTestGate()
        let started = expectation(description: "Slot occupied")
        let result = fixture()
        let first = Task {
            try await scheduler.run(key: "first") { _ in
                started.fulfill()
                await gate.wait()
                return result
            }
        }
        await fulfillment(of: [started], timeout: 2)
        let queued = Task {
            try await scheduler.run(key: "queued") { _ in
                XCTFail("A cancelled queued request cannot execute")
                return result
            }
        }
        queued.cancel()
        do { _ = try await queued.value; XCTFail("Expected cancellation") }
        catch is CancellationError { }
        await gate.open()
        _ = try await first.value
        _ = try await scheduler.run(key: "after") { _ in result }
    }

    func testConcurrencyIsBoundedAcrossDifferentAssets() async throws {
        let scheduler = AnalysisScheduler(maxConcurrentAnalyses: 2)
        let meter = AnalysisConcurrencyMeter()
        let result = fixture()
        try await withThrowingTaskGroup(of: MusicAnalysisResult.self) { group in
            for index in 0..<10 {
                group.addTask {
                    try await scheduler.run(key: "asset-\(index)") { _ in
                        await meter.enter()
                        try await Task.sleep(nanoseconds: 20_000_000)
                        await meter.leave()
                        return result
                    }
                }
            }
            for try await value in group { XCTAssertEqual(value, result) }
        }
        let peak = await meter.peak
        let total = await meter.total
        XCTAssertLessThanOrEqual(peak, 2)
        XCTAssertEqual(total, 10)
    }
}

private actor AnalysisTestGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func open() {
        isOpen = true
        let pending = waiters
        waiters.removeAll()
        for waiter in pending { waiter.resume() }
    }
}

private actor AnalysisConcurrencyMeter {
    private var active = 0
    private(set) var peak = 0
    private(set) var total = 0
    func enter() { active += 1; total += 1; peak = max(peak, active) }
    func leave() { active -= 1 }
}
