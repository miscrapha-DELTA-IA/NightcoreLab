import AVFoundation
import XCTest
@testable import NightcoreLab

final class PadInstrumentFeelTests: XCTestCase {
    func testRapidSamePadRetriggerKeepsEarlierVoicesUntilCapacity() throws {
        var pool = PadVoiceAllocator(capacity: 12)
        var chosen: [Int] = []
        for i in 0..<12 {
            let hit = try XCTUnwrap(pool.allocate(
                id: "snare", chokeGroup: nil, duration: 1.0,
                at: Double(i) * 0.025))
            XCTAssertFalse(hit.stoleVoice)
            XCTAssertTrue(hit.interrupted.isEmpty)
            chosen.append(hit.voiceIndex)
        }
        XCTAssertEqual(Set(chosen).count, 12)
        let overflow = try XCTUnwrap(pool.allocate(
            id: "snare", chokeGroup: nil, duration: 1.0, at: 0.35))
        XCTAssertTrue(overflow.stoleVoice)
        XCTAssertEqual(overflow.voiceIndex, chosen[0])
        XCTAssertEqual(overflow.interrupted.count, 1)
        XCTAssertEqual(overflow.interrupted.first?.previous.id, "snare")
        XCTAssertEqual(overflow.interrupted.first?.previous.began, 0)
    }

    func testChokePreservesIndependentDrumsAndCarriesPreviousHatLease() throws {
        var pool = PadVoiceAllocator(capacity: 4)
        let kick = try XCTUnwrap(pool.allocate(
            id: "kick", chokeGroup: nil, duration: 1, at: 0))
        let snare = try XCTUnwrap(pool.allocate(
            id: "snare", chokeGroup: nil, duration: 1, at: 0.03))
        let openHat = try XCTUnwrap(pool.allocate(
            id: "open-hat", chokeGroup: "hat", duration: 0.54, at: 0.04))
        let closedHat = try XCTUnwrap(pool.allocate(
            id: "closed-hat", chokeGroup: "hat", duration: 0.12, at: 0.06))
        XCTAssertEqual(closedHat.chokeIndices, [openHat.voiceIndex])
        XCTAssertEqual(closedHat.interrupted.map(\.previous.id), ["open-hat"])
        XCTAssertEqual(pool.leases[kick.voiceIndex].id, "kick")
        XCTAssertEqual(pool.leases[snare.voiceIndex].id, "snare")
        XCTAssertTrue(pool.leases.filter { $0.chokeGroup == "hat" &&
                                              $0.id != nil }.count == 1)
    }

    func testOfflineExportRetainsEightMillisecondReleaseForStealsAndChokes() throws {
        let kit = PadKit.starter
        let hits = [
            PadEvent(id: UUID(), padId: "open-hat", timestamp: 0.01,
                     velocity: 0.92, duration: 0.54, sourceTime: nil),
            PadEvent(id: UUID(), padId: "closed-hat", timestamp: 0.11,
                     velocity: 0.75, duration: 0.12, sourceTime: nil),
            PadEvent(id: UUID(), padId: "snare", timestamp: 0.17,
                     velocity: 0.9, duration: 0.28, sourceTime: nil),
            PadEvent(id: UUID(), padId: "snare", timestamp: 0.19,
                     velocity: 0.8, duration: 0.28, sourceTime: nil)
        ]
        let timeline = PerformanceTimeline(kitID: kit.id, events: hits)
        let schedule = try PerformancePadMixdown.schedule(
            timeline, kit: kit, startTime: 0, speed: 1,
            sampleRate: 48_000, polyphony: 1)
        XCTAssertEqual(schedule.count, 4)
        XCTAssertEqual(schedule[0].endFrame, Int64(0.11 * 48_000))
        XCTAssertEqual(schedule[0].releaseFrames, 384)
        XCTAssertEqual(schedule[2].endFrame, Int64(0.19 * 48_000))
        XCTAssertEqual(schedule[2].releaseFrames, 384)

        let wav = try PerformancePadMixdown.write(
            timeline, startTime: 0, speed: 1, duration: 0.6,
            sampleRate: 48_000)
        defer { try? FileManager.default.removeItem(at: wav) }
        let f = try AVAudioFile(forReading: wav,
                                commonFormat: .pcmFormatFloat32, interleaved: false)
        XCTAssertGreaterThan(f.length, 0)
    }

    func testTouchCancellationTracksEachPhysicalTouchIndependently() {
        var state = PadTouchState()
        let fingerA = NSObject()
        let fingerB = NSObject()
        let a = ObjectIdentifier(fingerA)
        let b = ObjectIdentifier(fingerB)
        XCTAssertTrue(state.begin(a))
        XCTAssertFalse(state.begin(a))
        XCTAssertTrue(state.begin(b))
        XCTAssertTrue(state.isPressed)
        // Cancelling finger A must never remove finger B's active press.
        XCTAssertTrue(state.end(a))
        XCTAssertTrue(state.isPressed)
        XCTAssertFalse(state.end(a))
        XCTAssertTrue(state.end(b))
        XCTAssertFalse(state.isPressed)
        state.begin(a)
        state.reset()
        XCTAssertFalse(state.isPressed)
    }

    func testVelocityIsRepeatableAndVariesWithHitZone() {
        let low = PadExpressiveness.velocity(verticalZone: 0, base: 0.85, hitIndex: 0)
        let high = PadExpressiveness.velocity(verticalZone: 1, base: 0.85, hitIndex: 0)
        let roll = PadExpressiveness.velocity(verticalZone: 1, base: 0.85, hitIndex: 1)
        XCTAssertLessThan(low, high)
        XCTAssertNotEqual(roll, high)
        XCTAssertEqual(high, PadExpressiveness.velocity(
            verticalZone: 1, base: 0.85, hitIndex: 4))
        XCTAssertEqual(PadExpressiveness.velocity(
            verticalZone: .nan, base: 0.85, hitIndex: 0), 0.85)
        XCTAssertTrue((0...1).contains(roll))
    }

    @MainActor
    func testSharedAudioGraphAcceptsDensePolyphonyWithNoDroppedPadTriggers() {
        let audio = AudioEngineManager()
        audio.beginPerformanceMode()
        XCTAssertTrue(audio.performancePadsReady)
        for i in 0..<32 {
            XCTAssertTrue(audio.triggerPad(i % 2 == 0 ? "kick" : "snare",
                                           velocity: 0.78))
        }
        XCTAssertTrue(audio.isAudioEngineRunning)
        audio.endPerformanceMode()
    }

    func testPerformanceEventSchemaAndOriginalKitStayCompatible() throws {
        let kit = PadKit.starter
        XCTAssertTrue(kit.isValid)
        XCTAssertEqual(kit.samples.count, 7)
        let timeline = PerformanceTimeline(kitID: kit.id,
            events: [PadEvent(id: UUID(), padId: "snare", timestamp: 0.125,
                              velocity: 0.77, duration: 0.28, sourceTime: nil)])
        let data = try JSONEncoder().encode(timeline)
        let decoded = try JSONDecoder().decode(PerformanceTimeline.self, from: data)
        XCTAssertEqual(decoded, timeline)
    }
}
