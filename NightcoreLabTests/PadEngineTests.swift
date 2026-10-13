import XCTest
import AVFoundation
@testable import NightcoreLab

final class PadEngineTests: XCTestCase {
    func testOriginalKitIsStableValidatedAndRightsClear() throws {
        let kit = PadKit.starter
        XCTAssertTrue(kit.isValid)
        XCTAssertEqual(kit.samples.count, 7)
        XCTAssertEqual(Set(kit.samples.map(\.id)),
                       Set(["kick", "snare", "closed-hat", "open-hat",
                            "clap", "crash", "808"]))
        XCTAssertTrue(kit.samples.allSatisfy {
            $0.license.contains("Original synthesized") && !$0.loop
        })
        XCTAssertEqual(kit.samples.first(where: { $0.id == "closed-hat" })?.chokeGroup, "hat")
        XCTAssertEqual(kit.samples.first(where: { $0.id == "open-hat" })?.chokeGroup, "hat")
        XCTAssertEqual(try JSONDecoder().decode(PadKit.self, from: JSONEncoder().encode(kit)), kit)
    }

    func testOriginalSamplesArePreloadableStereoFiniteAndNonSilent() throws {
        for descriptor in PadKit.starter.samples {
            let a = try XCTUnwrap(PadSampleSynthesizer.make(descriptor))
            XCTAssertEqual(a.format.sampleRate, 48_000)
            XCTAssertEqual(a.format.channelCount, 2)
            XCTAssertGreaterThan(a.frameLength, 0)
            let values = try XCTUnwrap(a.floatChannelData?[0])
            let count = Int(a.frameLength)
            var peak: Float = 0
            for i in 0..<count {
                XCTAssertTrue(values[i].isFinite)
                peak = max(peak, abs(values[i]))
            }
            XCTAssertGreaterThan(peak, 0.005, descriptor.id)
            XCTAssertLessThan(peak, 1.0, descriptor.id)
        }
    }

    func testVoiceAllocationHandlesPolyphonyAndStealing() {
        var allocator = PadVoiceAllocator(capacity: 2)
        let a = allocator.allocate(id: "kick", chokeGroup: nil,
                                   duration: 1, at: 0)!
        let b = allocator.allocate(id: "snare", chokeGroup: nil,
                                   duration: 1, at: 0.1)!
        XCTAssertNotEqual(a.voiceIndex, b.voiceIndex)
        let c = allocator.allocate(id: "clap", chokeGroup: nil,
                                   duration: 1, at: 0.2)!
        XCTAssertTrue(c.stoleVoice)
        XCTAssertEqual(c.voiceIndex, a.voiceIndex)
        let d = allocator.allocate(id: "808", chokeGroup: nil,
                                   duration: 0.5, at: 2)!
        XCTAssertFalse(d.stoleVoice)
    }

    func testOpenHatChokesClosedHatWithoutCuttingKick() {
        var allocator = PadVoiceAllocator(capacity: 3)
        let kick = allocator.allocate(id: "kick", chokeGroup: nil,
                                      duration: 1, at: 0)!
        let closed = allocator.allocate(id: "closed-hat", chokeGroup: "hat",
                                        duration: 1, at: 0.1)!
        let open = allocator.allocate(id: "open-hat", chokeGroup: "hat",
                                      duration: 1, at: 0.2)!
        XCTAssertEqual(open.chokeIndices, [closed.voiceIndex])
        XCTAssertNotEqual(open.voiceIndex, kick.voiceIndex)
        XCTAssertEqual(allocator.leases[kick.voiceIndex].id, "kick")
        allocator.reset()
        XCTAssertTrue(allocator.leases.allSatisfy { $0.id == nil })
    }

    @MainActor
    func testRecordedEventsAreVersionedOrderedAndBounded() throws {
        let recorder = PerformanceRecorder()
        let kick = try XCTUnwrap(PadKit.starter.samples.first)
        recorder.start(at: 10)
        recorder.append(kick, velocity: 0.9, sourceTime: 42, at: 10.2)
        recorder.append(kick, velocity: 0.6, sourceTime: 42.1, at: 10.3)
        recorder.stop()
        recorder.append(kick, velocity: 1, sourceTime: 45, at: 10.4)
        let timeline = recorder.timeline()
        XCTAssertEqual(timeline.version, 1)
        XCTAssertTrue(timeline.isValid)
        XCTAssertEqual(timeline.events.count, 2)
        XCTAssertEqual(timeline.events[0].timestamp, 0.2, accuracy: 0.0001)
        XCTAssertEqual(timeline.events[0].sourceTime, 42)
        let text = try XCTUnwrap(recorder.shareJSON())
        XCTAssertEqual(try JSONDecoder().decode(PerformanceTimeline.self,
                       from: Data(text.utf8)), timeline)
    }

    @MainActor
    func testPadRuntimeHasPreloadedSamplesBeforeTouch() {
        let runtime = PadAudioRuntime()
        XCTAssertTrue(runtime.isReady)
        XCTAssertEqual(runtime.nodes.count, 12)
        XCTAssertEqual(runtime.prepared.count, 7)
        XCTAssertFalse(runtime.trigger(padID: "unknown", velocity: 1))
        XCTAssertFalse(runtime.trigger(padID: "kick", velocity: .nan))
    }

    @MainActor
    func testExistingLiveEngineStillLoadsMusicAndAcceptsPads() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString + ".wav")
        defer { try? FileManager.default.removeItem(at: url) }
        let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2)!
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 88_200))
        buffer.frameLength = 88_200
        for c in 0..<2 {
            let d = try XCTUnwrap(buffer.floatChannelData?[c])
            for i in 0..<Int(buffer.frameLength) {
                d[i] = 0.03 * sin(Float(i) * 2 * .pi * 220 / 44_100)
            }
        }
        let wav = try AVAudioFile(forWriting: url, settings: format.settings)
        try wav.write(from: buffer)
        let audio = AudioEngineManager()
        XCTAssertTrue(audio.performancePadsReady)
        try audio.load(url: url)
        audio.play()
        XCTAssertTrue(audio.isPlaying)
        XCTAssertTrue(audio.triggerPad("kick"))
        XCTAssertTrue(audio.triggerPad("snare"))
        XCTAssertTrue(audio.isPlaying)
        XCTAssertEqual(audio.playbackCompletionCount, 0)
        audio.stopPerformancePads()
        XCTAssertTrue(audio.isPlaying)
        audio.pause()
    }
}
