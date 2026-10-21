import AVFoundation
import XCTest
@testable import NightcoreLab

@MainActor
final class StemPreparationLifetimeTests: XCTestCase {
    func testCancellationKeepsResourcesLeasedUntilWorkerReallyFinishes() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2)!
        let url = folder.appendingPathComponent("source.wav")
        try autoreleasepool {
            let file = try AVAudioFile(forWriting: url, settings: format.settings)
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 441)!
            buffer.frameLength = 441
            for channel in 0..<2 { buffer.floatChannelData![channel].update(repeating: 0, count: 441) }
            try file.write(from: buffer)
        }
        let gate = StemLifetimeGate()
        let started = expectation(description: "Prediction owns memory")
        let audio = AudioEngineManager(neuralPreparation: { _, _, _ in
            started.fulfill()
            await gate.wait() // Model predictions cannot be forcibly preempted.
            throw CancellationError()
        })
        try XCTSkipUnless(audio.hasNeuralStemModel, "Full IPA lane supplies the bundled model")
        try audio.load(url: url)
        audio.prepareNeuralStems()
        await fulfillment(of: [started], timeout: 12)
        audio.cancelStemPreparation()
        XCTAssertTrue(audio.isPreparingStems)
        XCTAssertTrue(audio.isCancellingStems)
        audio.prepareNeuralStems()
        XCTAssertTrue(audio.isCancellingStems, "Another tap must not enqueue a second prediction")
        do {
            _ = try await audio.exportAudio()
            XCTFail("An offline export cannot compete with a draining neural worker")
        } catch AudioEngineError.stemPreparationInProgress { }
        await gate.open()
        for _ in 0..<1_200 where audio.isPreparingStems {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertFalse(audio.isPreparingStems)
        XCTAssertFalse(audio.isCancellingStems)
        XCTAssertNil(audio.stemPreparationError)
    }
}

private actor StemLifetimeGate {
    private var opened = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        if opened { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func open() {
        opened = true
        let pending = waiters; waiters.removeAll()
        pending.forEach { $0.resume() }
    }
}
