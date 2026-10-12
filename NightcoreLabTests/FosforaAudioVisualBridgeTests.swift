import Foundation
import XCTest
@testable import NightcoreLab

final class FosforaAudioVisualBridgeTests: XCTestCase {
    private func point(_ time: Double, beat: Bool = false,
                       bass: Double = 0.4) -> AudioFeaturePoint {
        AudioFeaturePoint(
            time: time,
            features: AudioFeatures(bass: bass, mid: 0.2, treble: 0.1,
                                    energy: 0.5, beatDetected: beat))
    }

    func testOverflowDropsOldFramesButLatchesAllBeatEvents() async {
        let bus = AudioVisualFrameBus(capacity: 3)
        await bus.publish(point(0.00, beat: true))
        await bus.publish(point(0.08))
        await bus.publish(point(0.16, beat: true))
        await bus.publish(point(0.24))
        await bus.publish(point(0.32, beat: true))
        let latest = await bus.drainLatest()
        XCTAssertEqual(latest?.sourceTime, 0.32)
        XCTAssertEqual(latest?.beatSequence, 3)
        let dropped = await bus.droppedFrames
        XCTAssertEqual(dropped, 2)
        let drained = await bus.drainLatest()
        XCTAssertNil(drained)
    }

    func testSourceTimeRewindResetsCountersAndOldPackets() async {
        let bus = AudioVisualFrameBus(capacity: 2)
        await bus.publish(point(1.00, beat: true))
        await bus.publish(point(1.10, beat: true))
        await bus.publish(point(0.25))
        let snapshot = await bus.drainLatest()
        XCTAssertEqual(snapshot?.sourceTime, 0.25)
        XCTAssertEqual(snapshot?.beatSequence, 0)
        let dropped = await bus.droppedFrames
        XCTAssertEqual(dropped, 0)
    }

    func testDuplicateTimeDoesNotDuplicateOnset() async {
        let bus = AudioVisualFrameBus()
        await bus.publish(point(2.0, beat: true))
        await bus.publish(point(2.0, beat: true))
        let latest = await bus.drainLatest()
        XCTAssertEqual(latest?.beatSequence, 1)
    }

    func testSourceTimelineRetainsSkippedBeatPulses() {
        let timeline = AudioFeatureTimeline(points: [
            point(0.0),
            point(0.1, beat: true),
            point(0.2),
            point(0.3, beat: true),
            point(0.4),
            point(0.5, beat: true)
        ], duration: 0.6)
        XCTAssertEqual(timeline.beatCount(after: 0, through: 0.5), 3)
        XCTAssertEqual(timeline.beatCount(after: 0.1, through: 0.29), 0)
        XCTAssertEqual(timeline.beatCount(after: 0.1, through: 0.3), 1)
        XCTAssertEqual(timeline.beatCount(after: 0.5, through: 0.1), 0)
        XCTAssertEqual(timeline.beatCount(after: 0, through: 9), 0)
        XCTAssertEqual(timeline.features(at: 0.35).beatDetected, true)
    }

    func testNamedBindingsNeverEscapeNormalizedRange() throws {
        let bindings = CreativeVisualBindings()
        let preset = CreativePreset(
            id: "reactive", name: "Beat", theme: .acid,
            typographyStyle: .neon,
            visualStyle: VisualPreset(background: .marble, intensity: 1),
            audioReaction: .responsive)
        let response = AudioVisualMapper.map(
            AudioFeatures(bass: 1, mid: 1, treble: 1, energy: 1,
                          beatDetected: true), preset: preset)
        for target in CreativeVisualTarget.allCases {
            let value = bindings.value(for: target, response: response)
            XCTAssertTrue((0...1).contains(value), "\(target.rawValue) = \(value)")
            let data = try JSONEncoder().encode(target)
            XCTAssertEqual(try JSONDecoder().decode(CreativeVisualTarget.self,
                            from: data), target)
        }
        XCTAssertEqual(bindings.value(for: .playerGlow, response: .neutral), 0)
    }

    func testPauseImmediatelyClearsGlowAtFrozenMediaTime() async {
        let engine = AudioFeatureEngine()
        await engine.accept(AudioFeatureFrame(
            bassLevel: 1, midLevel: 0.8, trebleLevel: 0.5,
            rmsLevel: 1, beatDetected: true))
        let preset = CreativePreset(
            id: "playback-pause", name: "Test", theme: .acid,
            typographyStyle: .neon, visualStyle: VisualPreset(),
            audioReaction: .responsive)
        let playing = await engine.visualResponse(
            at: 5, preset: preset, isPlaying: true, lowPower: false)
        XCTAssertGreaterThan(playing?.glow ?? 0, 0)

        let paused = await engine.visualResponse(
            at: 5, preset: preset, isPlaying: false, lowPower: false)
        XCTAssertEqual(paused, .neutral)

        let resumed = await engine.visualResponse(
            at: 5, preset: preset, isPlaying: true, lowPower: false)
        XCTAssertNotNil(resumed, "Resume at the same timestamp must emit immediately")
        await engine.reset()
    }

    func testReactionOffReturnsNeutralAndRespectsNoOpPreset() {
        let preset = CreativePreset.current(
            theme: .noir, typographyStyle: .magazineCutout,
            playerBackground: .turbulent)
        let response = AudioVisualMapper.map(
            AudioFeatures(bass: 1, mid: 1, treble: 1,
                          energy: 1, beatDetected: true), preset: preset)
        XCTAssertEqual(response, .neutral)
    }
}
