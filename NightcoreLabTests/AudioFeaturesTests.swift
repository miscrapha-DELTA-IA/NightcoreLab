import Foundation
import XCTest
@testable import NightcoreLab

final class AudioFeaturesTests: XCTestCase {
    func testDefaultsRepresentSilenceNotInventedBeatOrEnergy() {
        let features = AudioFeatures()
        XCTAssertEqual(features, .silent)
        XCTAssertEqual(features.bass, 0)
        XCTAssertEqual(features.mid, 0)
        XCTAssertEqual(features.treble, 0)
        XCTAssertEqual(features.energy, 0)
        XCTAssertFalse(features.beatDetected)
    }

    func testExtremeAndNonFiniteValuesAreClamped() {
        let extreme = AudioFeatures(bass: -12, mid: 2.5, treble: .nan,
                                    energy: .infinity, beatDetected: true)
        XCTAssertEqual(extreme.bass, 0)
        XCTAssertEqual(extreme.mid, 1)
        XCTAssertEqual(extreme.treble, 0)
        XCTAssertEqual(extreme.energy, 0)
        XCTAssertTrue(extreme.beatDetected)

        let bounded = AudioFeatures(bass: 0.2, mid: 0.5,
                                    treble: 1, energy: 0.99)
        XCTAssertEqual(bounded.bass, 0.2)
        XCTAssertEqual(bounded.mid, 0.5)
        XCTAssertEqual(bounded.treble, 1)
        XCTAssertEqual(bounded.energy, 0.99)
    }

    func testDecodingAlsoClampsCorruptExternalValues() throws {
        let payload = Data("""
        {"bass":-8,"mid":2,"treble":0.5,"energy":0.75,"beatDetected":false}
        """.utf8)
        let features = try JSONDecoder().decode(AudioFeatures.self, from: payload)
        XCTAssertEqual(features.bass, 0)
        XCTAssertEqual(features.mid, 1)
        XCTAssertEqual(features.treble, 0.5)
        XCTAssertEqual(features.energy, 0.75)
        XCTAssertEqual(try JSONDecoder().decode(AudioFeatures.self,
                          from: JSONEncoder().encode(features)), features)
    }

    func testAudioFeatureEngineStartsInactiveAndReceivesExplicitInput() async {
        let engine = AudioFeatureEngine()
        let initial = await engine.snapshot()
        XCTAssertEqual(initial, .silent)

        let frame = AudioFeatureFrame(bassLevel: 0.7, midLevel: 0.4,
                                      trebleLevel: 2, rmsLevel: 0.8, beatDetected: true)
        let accepted = await engine.accept(frame)
        XCTAssertEqual(accepted.bass, 0.7)
        XCTAssertEqual(accepted.mid, 0.4)
        XCTAssertEqual(accepted.treble, 1)
        XCTAssertEqual(accepted.energy, 0.8)
        XCTAssertTrue(accepted.beatDetected)
        let updated = await engine.snapshot()
        XCTAssertEqual(updated, accepted)

        await engine.reset()
        let resetValue = await engine.snapshot()
        XCTAssertEqual(resetValue, .silent)
    }
}
