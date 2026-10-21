import AVFoundation
import Observation
import XCTest
@testable import NightcoreLab

@MainActor
final class StemPreparationLifetimeTests: XCTestCase {
    private func waitForCompletion(of audio: AudioEngineManager) async {
        let finished = expectation(description: "Preparation completed and released its lease")
        let observer = PreparationCompletionObserver(audio: audio) { finished.fulfill() }
        observer.observe()
        // These are lifecycle assertions, not a disk/CPU latency benchmark.
        // Observe completion instead of racing it with periodic reads.
        await fulfillment(of: [finished], timeout: 30)
        observer.stop()
        XCTAssertFalse(audio.isPreparingStems)
    }

    func testChangingSongsKeepsPreparationAliveAndAttachesOnlyToItsOriginalSong() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2)!
        func write(_ name: String, frames: AVAudioFrameCount) throws -> URL {
            let url = folder.appendingPathComponent(name + ".wav")
            try autoreleasepool {
                let file = try AVAudioFile(forWriting: url, settings: format.settings)
                let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
                buffer.frameLength = frames
                for channel in 0..<2 { buffer.floatChannelData![channel].update(repeating: 0.02, count: Int(frames)) }
                try file.write(from: buffer)
            }
            return url
        }
        let first = try write("first", frames: 4_410), second = try write("second", frames: 8_820)
        let urls = try Dictionary(uniqueKeysWithValues: StemKind.allCases.map { ($0, try write($0.rawValue, frames: 4_410)) })
        let gate = StemLifetimeGate()
        let started = expectation(description: "First song preparation started")
        let audio = AudioEngineManager(neuralPreparation: { source, _, _, _ in
            XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
            started.fulfill(); await gate.wait()
            try Task.checkCancellation()
            return StemAsset(urls: urls, source: .demucs)
        })
        try XCTSkipUnless(audio.hasNeuralStemModel)
        try audio.load(url: first); audio.prepareNeuralStems()
        await fulfillment(of: [started], timeout: 30)
        try audio.load(url: second)
        XCTAssertTrue(audio.isPreparingStems)
        XCTAssertFalse(audio.isCancellingStems)
        await gate.open()
        await waitForCompletion(of: audio)
        XCTAssertNil(audio.stemPreparationError)
        XCTAssertFalse(audio.stemsAvailable, "The first song's stems must not attach to the second song")
        try audio.load(url: first)
        XCTAssertTrue(audio.stemsAvailable)
        XCTAssertEqual(audio.stemSource, .demucs)
    }

    func testCompletedPreparationPreservesRoformerSourceAndEnablesMixer() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2)!
        func write(_ name: String, value: Float) throws -> URL {
            let url = folder.appendingPathComponent(name + ".wav")
            try autoreleasepool {
                let file = try AVAudioFile(forWriting: url, settings: format.settings)
                let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4410)!
                buffer.frameLength = 4410
                for channel in 0..<2 { buffer.floatChannelData![channel].update(repeating: value, count: 4410) }
                try file.write(from: buffer)
            }
            return url
        }
        let source = try write("source", value: 0.1)
        let urls = try Dictionary(uniqueKeysWithValues: StemKind.allCases.map {
            ($0, try write($0.rawValue, value: 0.025))
        })
        let asset = StemAsset(urls: urls, source: .roformer)
        let audio = AudioEngineManager(neuralPreparation: { _, _, _, _ in asset })
        try XCTSkipUnless(audio.hasNeuralStemModel, "The focused lane reuses the verified model bundle")
        try audio.load(url: source)
        audio.prepareNeuralStems()
        await waitForCompletion(of: audio)
        XCTAssertNil(audio.stemPreparationError)
        XCTAssertTrue(audio.stemsAvailable)
        XCTAssertEqual(audio.stemSource, .roformer)
        audio.setStemLevel(.vocal, level: 0)
        XCTAssertTrue(audio.stemMixEnabled)
        XCTAssertEqual(audio.stemLevels[.vocal], 0)
    }

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
        let audio = AudioEngineManager(neuralPreparation: { _, _, _, _ in
            started.fulfill()
            await gate.wait() // Model predictions cannot be forcibly preempted.
            throw CancellationError()
        })
        try XCTSkipUnless(audio.hasNeuralStemModel, "Full IPA lane supplies the bundled model")
        try audio.load(url: url)
        audio.prepareNeuralStems()
        await fulfillment(of: [started], timeout: 30)
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
        await waitForCompletion(of: audio)
        XCTAssertFalse(audio.isPreparingStems)
        XCTAssertFalse(audio.isCancellingStems)
        XCTAssertNil(audio.stemPreparationError)
    }
}

@MainActor
private final class PreparationCompletionObserver {
    private let audio: AudioEngineManager
    private let completion: () -> Void
    private var observing = true

    init(audio: AudioEngineManager, completion: @escaping () -> Void) {
        self.audio = audio
        self.completion = completion
    }

    func observe() {
        guard observing else { return }
        let preparing = withObservationTracking {
            audio.isPreparingStems
        } onChange: { [weak self] in
            Task { @MainActor in self?.observe() }
        }
        if !preparing {
            observing = false
            completion()
        }
    }

    func stop() { observing = false }
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
