import XCTest
import AVFoundation
@testable import NightcoreLab

final class PerformanceSourceClipTests: XCTestCase {
    private func sineWAV(channels: AVAudioChannelCount = 2,
                         rate: Double = 44_100, seconds: Double = 2) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(
            "sample-picker-test-\(UUID().uuidString).wav")
        let format = AVAudioFormat(standardFormatWithSampleRate: rate,
                                   channels: channels)!
        let frames = AVAudioFrameCount(seconds * rate)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(
            pcmFormat: format, frameCapacity: frames))
        buffer.frameLength = frames
        for c in 0..<Int(channels) {
            let values = try XCTUnwrap(buffer.floatChannelData?[c])
            for i in 0..<Int(frames) {
                values[i] = 0.18 * sin(Float(i) * 2 * .pi * 330 / Float(rate))
            }
        }
        var writer: AVAudioFile? = try AVAudioFile(forWriting: url, settings: format.settings)
        try writer?.write(from: buffer)
        writer = nil
        return url
    }

    func testClipBoundsRejectOutOfRangeOrNonfinite() {
        XCTAssertNil(PerformanceSourceClip(startTime: 0, duration: 0.1, sourceDuration: 10))
        XCTAssertNil(PerformanceSourceClip(startTime: 0, duration: 6, sourceDuration: 10))
        XCTAssertNil(PerformanceSourceClip(startTime: -1, duration: 1, sourceDuration: 10))
        XCTAssertNil(PerformanceSourceClip(startTime: 9, duration: 2, sourceDuration: 10))
        XCTAssertNil(PerformanceSourceClip(startTime: .nan, duration: 1, sourceDuration: 10))
        XCTAssertNil(PerformanceSourceClip(startTime: 0, duration: 1, sourceDuration: .infinity))
        let clip = PerformanceSourceClip(startTime: 0.5, duration: 1.5, sourceDuration: 2)
        XCTAssertEqual(clip?.endTime, 2)
        XCTAssertEqual(clip?.descriptor.id, PerformanceSourceClip.slotID)
        XCTAssertEqual(clip?.descriptor.loop, false)
    }

    func testOldPerformanceTimelineV1DecodesWithoutClipField() throws {
        let json = #"{"version":1,"kitID":"nightcore-original-drums-v1","events":[]}"#
        let timeline = try JSONDecoder().decode(PerformanceTimeline.self,
                                                 from: Data(json.utf8))
        XCTAssertNil(timeline.sourceClip)
        XCTAssertTrue(timeline.isValid)
        XCTAssertEqual(timeline.events.count, 0)
    }

    func testClipPCMDecodeStereoAndMonoInBounds() throws {
        for channels in [AVAudioChannelCount(1), 2] {
            let url = try sineWAV(channels: channels)
            defer { try? FileManager.default.removeItem(at: url) }
            let clip = try XCTUnwrap(PerformanceSourceClip(
                startTime: 0.5, duration: 0.6, sourceDuration: 2))
            let pcm = try PerformanceClipExtractor.decode(from: url, clip: clip)
            XCTAssertEqual(pcm.left.count, 28_800)
            XCTAssertEqual(pcm.right.count, 28_800)
            XCTAssertTrue(pcm.left.allSatisfy(\.isFinite))
            XCTAssertTrue(pcm.right.allSatisfy(\.isFinite))
            XCTAssertGreaterThan(pcm.left.map { abs($0) }.max() ?? 0, 0.10)
            let buffer = try XCTUnwrap(pcm.makeBuffer())
            XCTAssertEqual(buffer.frameLength, 28_800)
            XCTAssertEqual(buffer.format.sampleRate, 48_000)
            XCTAssertEqual(buffer.format.channelCount, 2)
        }
    }

    func testSourceClipEventsSurviveJSONAndOfflineMixWithNoSourceURLSerialized() throws {
        let url = try sineWAV()
        defer { try? FileManager.default.removeItem(at: url) }
        let clip = try XCTUnwrap(PerformanceSourceClip(
            startTime: 0.2, duration: 0.5, sourceDuration: 2))
        let event = PadEvent(id: UUID(), padId: PerformanceSourceClip.slotID,
                             timestamp: 0.4, velocity: 0.9,
                             duration: clip.duration, sourceTime: 0.4)
        let timeline = PerformanceTimeline(kitID: PadKit.starter.id,
                                            events: [event], sourceClip: clip)
        XCTAssertTrue(timeline.isValid)
        let encoded = try JSONEncoder().encode(timeline)
        let decoded = try JSONDecoder().decode(PerformanceTimeline.self,
                                                from: encoded)
        XCTAssertEqual(decoded, timeline)
        let json = String(decoding: encoded, as: UTF8.self)
        XCTAssertFalse(json.contains(url.path))
        XCTAssertFalse(json.contains("file://"))
        let hits = try PerformancePadMixdown.schedule(timeline, kit: .starter,
                                  startTime: 0, speed: 1, sampleRate: 48_000)
        XCTAssertEqual(hits.first?.sample.id, PerformanceSourceClip.slotID)
        let stem = try PerformancePadMixdown.write(
            timeline, startTime: 0, speed: 1, duration: 1.2,
            sampleRate: 44_100, sourceURL: url)
        defer { try? FileManager.default.removeItem(at: stem) }
        let audio = try AVAudioFile(forReading: stem,
                                    commonFormat: .pcmFormatFloat32, interleaved: false)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(
            pcmFormat: audio.processingFormat,
            frameCapacity: AVAudioFrameCount(audio.length)))
        try audio.read(into: buffer)
        let samples = try XCTUnwrap(buffer.floatChannelData?[0])
        XCTAssertEqual(samples[0], 0)
        XCTAssertGreaterThan(
            (20_000..<30_000).map { abs(samples[$0]) }.max() ?? 0, 0.04)
    }

    @MainActor
    func testClipAssignmentAndTrackReplacementInvalidatePreparedBuffer() async throws {
        let url = try sineWAV()
        defer { try? FileManager.default.removeItem(at: url) }
        let audio = AudioEngineManager()
        try audio.load(url: url)
        let firstRevision = audio.playbackSourceRevision
        let clip = try await audio.assignPerformanceSourceClip(
            startTime: 0.2, duration: 0.5, expectedRevision: firstRevision)
        XCTAssertEqual(audio.performanceSourceClip, clip)
        XCTAssertTrue(audio.triggerPad(PerformanceSourceClip.slotID))
        try audio.load(url: url)
        XCTAssertNil(audio.performanceSourceClip)
        XCTAssertFalse(audio.triggerPad(PerformanceSourceClip.slotID))
        XCTAssertNotEqual(audio.playbackSourceRevision, firstRevision)
        do {
            _ = try await audio.assignPerformanceSourceClip(
                startTime: 0.2, duration: 0.5, expectedRevision: firstRevision)
            XCTFail("A stale source revision must reject clip assignment")
        } catch {
            XCTAssertNil(audio.performanceSourceClip)
        }
    }
}
