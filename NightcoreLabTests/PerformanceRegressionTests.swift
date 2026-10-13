import XCTest
import AVFoundation
@testable import NightcoreLab

final class PerformanceRegressionTests: XCTestCase {
    private func source() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".wav")
        let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 441_000)!
        buffer.frameLength = buffer.frameCapacity
        for channel in 0..<2 {
            for i in 0..<Int(buffer.frameLength) {
                buffer.floatChannelData![channel][i] = Float(sin(Double(i) * 2 * .pi * 440 / 44_100)) * 0.05
            }
        }
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    @MainActor
    func testLongPauseRetainsSeekSettingsAndResumesWithoutFalseCompletion() async throws {
        let audio = AudioEngineManager(idleStopDelay: .milliseconds(50))
        try audio.load(url: source())
        audio.setSpeed(1.25)
        audio.setBass(3)
        audio.play()
        XCTAssertTrue(audio.isAudioEngineRunning)
        audio.pause()
        audio.seek(to: 3)
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertFalse(audio.isAudioEngineRunning)
        XCTAssertFalse(audio.isPlaying)
        XCTAssertEqual(audio.playbackTime, 3, accuracy: 0.001)
        XCTAssertEqual(audio.lyricsClock.lyricTime, 3, accuracy: 0.001)
        XCTAssertEqual(audio.playbackCompletionCount, 0)
        // Seeking after the engine is already suspended must also survive resume.
        audio.seek(to: 4)
        audio.play()
        XCTAssertTrue(audio.isPlaying)
        XCTAssertTrue(audio.isAudioEngineRunning)
        XCTAssertEqual(audio.speed, 1.25)
        XCTAssertEqual(audio.bass, 3)
        XCTAssertGreaterThanOrEqual(audio.playbackTime, 3.9)
        audio.pause()
        try await Task.sleep(for: .milliseconds(250))
    }

    @MainActor
    func testShortPauseAndTrackReplacementCancelOldDeadline() async throws {
        let audio = AudioEngineManager(idleStopDelay: .milliseconds(150))
        let first = try source(), second = try source()
        try audio.load(url: first)
        audio.play()
        audio.pause()
        XCTAssertTrue(audio.isAudioEngineRunning)
        audio.play()
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertTrue(audio.isAudioEngineRunning)
        XCTAssertTrue(audio.isPlaying)
        audio.pause()
        try audio.load(url: second)
        audio.play()
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertTrue(audio.isPlaying)
        XCTAssertTrue(audio.isAudioEngineRunning)
        XCTAssertEqual(audio.playbackCompletionCount, 0)
        audio.pause()
        try await Task.sleep(for: .milliseconds(300))
    }

    @MainActor
    func testSeekToEndThenPlayRestarts() async throws {
        let audio = AudioEngineManager(idleStopDelay: .milliseconds(50))
        try audio.load(url: source())
        audio.seek(to: audio.duration)
        XCTAssertEqual(audio.playbackTime, audio.duration)
        audio.play()
        XCTAssertTrue(audio.isPlaying)
        XCTAssertLessThan(audio.playbackTime, 1)
        audio.pause()
        try await Task.sleep(for: .milliseconds(250))
    }

    @MainActor
    func testInterruptionUsesSameSafePausePath() async throws {
        let audio = AudioEngineManager(idleStopDelay: .milliseconds(50))
        try audio.load(url: source())
        audio.play()
        NotificationCenter.default.post(name: AVAudioSession.interruptionNotification,
            object: nil, userInfo: [AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.began.rawValue])
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertFalse(audio.isPlaying)
        XCTAssertFalse(audio.isAudioEngineRunning)
        XCTAssertEqual(audio.playbackCompletionCount, 0)
        audio.play()
        XCTAssertTrue(audio.isPlaying)
        audio.pause()
        try await Task.sleep(for: .milliseconds(250))
    }

    func testLocalMetricsBoundedAndNumericOnly() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = LocalPerformanceMetrics(directory: folder)
        store.record((0..<100).map { LocalPerformanceSample(cpuSeconds: Double($0)) })
        let samples = await store.storedSamples()
        XCTAssertEqual(samples.count, 30)
        XCTAssertEqual(samples.first?.cpuSeconds, 70)
        XCTAssertEqual(samples.last?.cpuSeconds, 99)
        let restored = LocalPerformanceMetrics(directory: folder)
        let disk = await restored.storedSamples()
        XCTAssertEqual(samples, disk)
        let data = try JSONEncoder().encode(samples)
        XCTAssertLessThan(data.count, LocalPerformanceMetrics.byteLimit)
        let objects = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [[String: Any]])
        XCTAssertEqual(Set(objects.flatMap { $0.keys }), ["cpuSeconds"])
        let excluded = try folder.appendingPathComponent("LocalPerformance")
            .resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup
        XCTAssertEqual(excluded, true)
    }
}
