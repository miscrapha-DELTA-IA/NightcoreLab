import AVFoundation
import Foundation
import XCTest
@testable import NightcoreLab

/// Stage 12.5 — Rhythm real-world validation.
///
/// Representative, deterministic genre fixtures (same generators as the
/// Python prototype in docs/RHYTHM_REAL_WORLD_VALIDATION_STAGE12_5.md):
/// constant EDM, house with loud off-beat open hats, rock with human drift,
/// swung hip hop, a tempo ramp, music without drums and silence. Each test
/// measures BPM, confidence and phase stability (share of true beats with a
/// tracked beat within ±50 ms, and the inter-beat coefficient of variation).
///
/// Real tracks can be added without committing audio: set
/// `TEST_RUNNER_NIGHTCORE_RHYTHM_FIXTURES` to a folder containing
/// `manifest.json` (`[{"file": "song.m4a", "bpm": 128, "drums": true}]`).
final class RhythmGenreFixtureTests: XCTestCase {
    private static let sampleRate: Double = 22_050

    // MARK: Deterministic synthesis

    private struct Noise {
        var state: UInt64
        mutating func next() -> Double {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Double(state >> 11) / Double(UInt64(1) << 53) * 2 - 1
        }
    }

    private struct Fixture {
        var samples: [Double]
        var beats: [Double] = []

        init(seconds: Double) {
            samples = [Double](repeating: 0, count: Int(seconds * RhythmGenreFixtureTests.sampleRate))
        }

        mutating func add(_ sound: [Double], at time: Double) {
            let start = Int(time * RhythmGenreFixtureTests.sampleRate)
            guard start >= 0, start < samples.count else { return }
            let count = min(sound.count, samples.count - start)
            for index in 0..<count { samples[start + index] += sound[index] }
        }

        var channels: [[Float]] { [samples.map { Float($0) }] }
    }

    private static func decay(_ index: Int, _ rate: Double) -> Double {
        exp(-Double(index) / sampleRate * rate)
    }

    /// Pitch-swept sine kick (140 → 50 Hz).
    private static func kick(_ gain: Double = 1) -> [Double] {
        let count = Int(0.25 * sampleRate)
        var phase: Double = 0
        var out = [Double](repeating: 0, count: count)
        for index in 0..<count {
            let t: Double = Double(index) / sampleRate
            let frequency: Double = 50 + 90 * exp(-t * 30)
            phase += 2 * Double.pi * frequency / sampleRate
            out[index] = gain * 0.9 * sin(phase) * decay(index, 12)
        }
        return out
    }

    private static func snare(_ noise: inout Noise, gain: Double = 1) -> [Double] {
        let count = Int(0.2 * sampleRate)
        var out = [Double](repeating: 0, count: count)
        for index in 0..<count {
            let t: Double = Double(index) / sampleRate
            let body: Double = 0.2 * sin(2 * Double.pi * 190 * t) * decay(index, 30)
            out[index] = gain * (0.5 * noise.next() * decay(index, 22) + body)
        }
        return out
    }

    /// Differenced (high-passed) noise burst.
    private static func hat(_ noise: inout Noise, gain: Double = 1) -> [Double] {
        let count = Int(0.04 * sampleRate)
        var out = [Double](repeating: 0, count: count)
        var previous: Double = 0
        for index in 0..<count {
            let value = noise.next()
            out[index] = gain * 0.12 * (value - previous) * decay(index, 90)
            previous = value
        }
        return out
    }

    private static func tone(_ frequency: Double, seconds: Double, gain: Double,
                             rate: Double) -> [Double] {
        let count = Int(seconds * sampleRate)
        var out = [Double](repeating: 0, count: count)
        for index in 0..<count {
            let t: Double = Double(index) / sampleRate
            out[index] = gain * sin(2 * Double.pi * frequency * t) * decay(index, rate)
        }
        return out
    }

    /// Four-on-the-floor kick, snare on 2/4, 16th hats, off-beat bass, pad.
    private static func edm(bpm: Double = 128, seconds: Double = 30, seed: UInt64 = 1) -> Fixture {
        var noise = Noise(state: seed)
        var fixture = Fixture(seconds: seconds)
        let period: Double = 60 / bpm
        let bass = tone(55, seconds: period / 2, gain: 0.25, rate: 4)
        var time: Double = 0.5
        var beat = 0
        while time < seconds - 0.3 {
            fixture.beats.append(time)
            fixture.add(kick(), at: time)
            if beat % 2 == 1 { fixture.add(snare(&noise), at: time) }
            for step in 0..<4 {
                fixture.add(hat(&noise), at: time + Double(step) * period / 4)
            }
            fixture.add(bass, at: time + period / 2)
            time += period
            beat += 1
        }
        for index in fixture.samples.indices {
            let t: Double = Double(index) / sampleRate
            let swell: Double = 0.6 + 0.4 * sin(2 * Double.pi * 0.1 * t)
            fixture.samples[index] += 0.05 * sin(2 * Double.pi * 220 * t) * swell
        }
        return fixture
    }

    /// Kick on every beat, light snare on 2/4 and a LOUD open hat on every
    /// off-beat: broadband flux is larger off the beat than on it.
    private static func house(bpm: Double = 124, seconds: Double = 30, seed: UInt64 = 6) -> Fixture {
        var noise = Noise(state: seed)
        var fixture = Fixture(seconds: seconds)
        let period: Double = 60 / bpm
        let openCount = Int(0.18 * sampleRate)
        var time: Double = 0.5
        var beat = 0
        while time < seconds - 0.3 {
            fixture.beats.append(time)
            fixture.add(kick(), at: time)
            if beat % 2 == 1 { fixture.add(snare(&noise, gain: 0.6), at: time) }
            var open = [Double](repeating: 0, count: openCount)
            for index in 0..<openCount { open[index] = 0.35 * noise.next() * decay(index, 12) }
            fixture.add(open, at: time + period / 2)
            time += period
            beat += 1
        }
        return fixture
    }

    /// Kick 1/3, snare 2/4, 8th hats, random off-beat kicks, ±8 ms timing,
    /// ±1.5 % slow tempo drift and square-wave guitars.
    private static func rock(bpm: Double = 120, seconds: Double = 30, seed: UInt64 = 2) -> Fixture {
        var noise = Noise(state: seed)
        var fixture = Fixture(seconds: seconds)
        var time: Double = 0.4
        var beat = 0
        while time < seconds - 0.3 {
            let drift: Double = 1 + 0.015 * sin(2 * Double.pi * time / 17)
            let period: Double = 60 / (bpm * drift)
            let played: Double = time + 0.008 * noise.next()
            fixture.beats.append(played)
            if beat % 4 == 0 || beat % 4 == 2 { fixture.add(kick(), at: played) }
            if beat % 4 == 1 || beat % 4 == 3 { fixture.add(snare(&noise, gain: 1.3), at: played) }
            if noise.next() < -0.5 { fixture.add(kick(0.7), at: played + period / 2) }
            fixture.add(hat(&noise), at: played)
            fixture.add(hat(&noise), at: played + period / 2)
            time += period
            beat += 1
        }
        for index in fixture.samples.indices {
            let t: Double = Double(index) / sampleRate
            var guitar: Double = 0
            for (frequency, gain) in [(110.0, 0.06), (165.0, 0.05), (220.0, 0.04)] {
                let wave: Double = sin(2 * Double.pi * frequency * t)
                guitar += gain * (wave >= 0 ? 1 : -1)
            }
            fixture.samples[index] += guitar * (0.7 + 0.3 * sin(2 * Double.pi * 0.25 * t))
        }
        return fixture
    }

    /// Boom-bap: syncopated kicks, heavy snare on 2/4, swung 16th hats, 808.
    private static func hipHop(bpm: Double = 90, seconds: Double = 30, seed: UInt64 = 3) -> Fixture {
        var noise = Noise(state: seed)
        var fixture = Fixture(seconds: seconds)
        let period: Double = 60 / bpm
        let sub = tone(45, seconds: 1.2 * period, gain: 0.4, rate: 1.5)
        var time: Double = 0.3
        var beat = 0
        while time < seconds - 0.3 {
            fixture.beats.append(time)
            if beat % 4 == 0 {
                fixture.add(kick(), at: time)
                fixture.add(kick(0.8), at: time + 0.75 * period)
                fixture.add(sub, at: time)
            }
            if beat % 4 == 2 { fixture.add(kick(), at: time + 0.5 * period) }
            if beat % 2 == 1 { fixture.add(snare(&noise, gain: 1.4), at: time) }
            for step in 0..<4 {
                let swing: Double = step % 2 == 1 ? 0.06 * period : 0
                fixture.add(hat(&noise, gain: 0.8), at: time + Double(step) * period / 4 + swing)
            }
            time += period
            beat += 1
        }
        return fixture
    }

    /// 100 → 130 BPM over the whole fixture.
    private static func ramp(seconds: Double = 40, seed: UInt64 = 4) -> Fixture {
        var noise = Noise(state: seed)
        var fixture = Fixture(seconds: seconds)
        var time: Double = 0.5
        var beat = 0
        while time < seconds - 0.3 {
            let bpm: Double = 100 + 30 * time / seconds
            let period: Double = 60 / bpm
            fixture.beats.append(time)
            fixture.add(kick(), at: time)
            if beat % 2 == 1 { fixture.add(snare(&noise), at: time) }
            fixture.add(hat(&noise), at: time + period / 2)
            time += period
            beat += 1
        }
        return fixture
    }

    /// Sustained chords with soft attacks and rubato changes; no percussion.
    private static func noDrums(seconds: Double = 30, seed: UInt64 = 5) -> Fixture {
        var noise = Noise(state: seed)
        var fixture = Fixture(seconds: seconds)
        let roots: [Double] = [220, 196, 174.6, 261.6]
        let ratios: [Double] = [1, 1.26, 1.5, 2]
        var time: Double = 0.3
        while time < seconds - 1 {
            let root = roots[min(3, Int((noise.next() + 1) * 2))]
            let count = Int(min(3.5, seconds - time) * sampleRate)
            var chord = [Double](repeating: 0, count: count)
            for index in 0..<count {
                let t: Double = Double(index) / sampleRate
                let shape: Double = min(1, t / 0.08) * exp(-t * 0.9)
                var sum: Double = 0
                for (k, ratio) in ratios.enumerated() {
                    sum += sin(2 * Double.pi * root * ratio * t) / Double(k + 1)
                }
                chord[index] = 0.15 * sum * shape
            }
            fixture.add(chord, at: time)
            time += 2.1 + 0.5 * noise.next()
        }
        return fixture
    }

    // MARK: Measurement

    private struct Measurement: CustomStringConvertible {
        let bpm: Double?
        let confidence: Float
        let quality: RhythmAnalysisResult.Quality
        /// Share of interior true beats with a tracked beat within ±50 ms.
        let withinTolerance: Double
        let medianError: Double
        /// Coefficient of variation of the tracked inter-beat intervals.
        let intervalVariation: Double

        var description: String {
            let tempo: String = bpm.map { String(format: "%.1f", $0) } ?? "-"
            let conf: String = String(format: "%.2f", Double(confidence))
            let share: String = String(format: "%.0f", withinTolerance * 100)
            let median: String = String(format: "%.1f", medianError * 1000)
            let cv: String = String(format: "%.3f", intervalVariation)
            return "bpm \(tempo) conf \(conf) (\(quality.rawValue)) beats±50ms \(share)% "
                + "median \(median) ms ibiCV \(cv)"
        }
    }

    private func measure(_ fixture: Fixture) throws -> (RhythmAnalysisResult, Measurement) {
        let result = try RhythmAnalyzer.analyze(channels: fixture.channels,
                                                sampleRate: Self.sampleRate)
        let grid: [Double] = result.beatGrid.map { $0.time }
        let interior: [Double] = Array(fixture.beats.dropFirst(4).dropLast(4))
        var errors: [Double] = []
        for truth in interior {
            errors.append(grid.map { abs($0 - truth) }.min() ?? .infinity)
        }
        let hits: Int = errors.filter { (error: Double) -> Bool in error < 0.05 }.count
        let sorted = errors.sorted()
        let intervals: [Double] = zip(grid.dropFirst(), grid).map { $0 - $1 }
        var variation: Double = 1
        if intervals.count > 1 {
            let total: Double = intervals.reduce(0.0) { (sum: Double, value: Double) -> Double in sum + value }
            let mean: Double = total / Double(intervals.count)
            let spread: Double = intervals.reduce(0.0) { (sum: Double, value: Double) -> Double in
                sum + (value - mean) * (value - mean)
            }
            variation = mean > 0 ? (spread / Double(intervals.count)).squareRoot() / mean : 1
        }
        let measurement = Measurement(
            bpm: result.bpmCandidates.first?.bpm,
            confidence: result.confidence,
            quality: result.quality,
            withinTolerance: interior.isEmpty ? 0 : Double(hits) / Double(interior.count),
            medianError: sorted.isEmpty ? .infinity : sorted[sorted.count / 2],
            intervalVariation: variation)
        return (result, measurement)
    }

    private func assertSteadyGenre(_ name: String, _ fixture: Fixture, bpm: Double,
                                   bpmTolerance: Double = 1.5,
                                   minimumConfidence: Float = 0.5,
                                   file: StaticString = #filePath, line: UInt = #line) throws {
        let (result, m) = try measure(fixture)
        print("[Rhythm 12.5] \(name): \(m)")
        let tempo = try XCTUnwrap(m.bpm, "\(name): no tempo", file: file, line: line)
        XCTAssertEqual(tempo, bpm, accuracy: bpmTolerance, "\(name) BPM", file: file, line: line)
        XCTAssertGreaterThanOrEqual(m.confidence, minimumConfidence, "\(name) confidence",
                                    file: file, line: line)
        XCTAssertGreaterThanOrEqual(m.withinTolerance, 0.9, "\(name) phase", file: file, line: line)
        XCTAssertLessThan(m.medianError, 0.02, "\(name) median phase error", file: file, line: line)
        XCTAssertLessThan(m.intervalVariation, 0.05, "\(name) beat stability", file: file, line: line)
        XCTAssertTrue(result.isValid(through: Double(fixture.samples.count) / Self.sampleRate),
                      name, file: file, line: line)
    }

    // MARK: Genres

    /// v2 tracked 64 BPM (every other beat).
    func testConstantEDM() throws {
        try assertSteadyGenre("EDM 128", Self.edm(), bpm: 128)
        try assertSteadyGenre("EDM 140", Self.edm(bpm: 140, seed: 11), bpm: 140)
    }

    /// v2 locked onto the off-beat hats (0 % of beats within 50 ms).
    func testHouseWithLoudOffbeatHatsKeepsTheKickPhase() throws {
        try assertSteadyGenre("House 124", Self.house(), bpm: 124)
        try assertSteadyGenre("House 128", Self.house(bpm: 128, seed: 12), bpm: 128)
    }

    /// v2 tracked 60 BPM (kick/snare repeat every two beats).
    func testRockWithHumanDrift() throws {
        try assertSteadyGenre("Rock 120", Self.rock(), bpm: 120, bpmTolerance: 2.5,
                              minimumConfidence: 0.4)
        try assertSteadyGenre("Rock 150", Self.rock(bpm: 150, seed: 11), bpm: 150,
                              bpmTolerance: 3, minimumConfidence: 0.4)
    }

    /// v2 tracked 179 BPM (swung 16th hats).
    func testSwungHipHop() throws {
        try assertSteadyGenre("Hip hop 90", Self.hipHop(), bpm: 90)
    }

    /// Known octave ambiguity: slow hip hop may be reported at double tempo,
    /// but every real beat must still be tracked.
    func testSlowHipHopTracksEveryBeatAtEitherOctave() throws {
        let (_, m) = try measure(Self.hipHop(bpm: 75, seed: 11))
        print("[Rhythm 12.5] Hip hop 75: \(m)")
        let tempo = try XCTUnwrap(m.bpm)
        XCTAssertTrue(abs(tempo - 75) <= 1.5 || abs(tempo - 150) <= 3, "\(tempo)")
        XCTAssertGreaterThanOrEqual(m.withinTolerance, 0.9)
    }

    /// Known limit: a 30 % tempo ramp has no single period. The analyzer may
    /// lock onto half tempo, but it must not claim high confidence.
    func testTempoRampIsNotReportedAsHighConfidence() throws {
        let fixture = Self.ramp()
        let (result, m) = try measure(fixture)
        print("[Rhythm 12.5] Ramp 100→130: \(m)")
        XCTAssertNotEqual(m.quality, .high)
        XCTAssertTrue(result.isValid(through: Double(fixture.samples.count) / Self.sampleRate))
    }

    /// v2 reported 0.49–0.52 confidence (a visible pulse) on drumless music.
    func testMusicWithoutDrumsDoesNotDriveAPulse() throws {
        for seed: UInt64 in [5, 10, 11] {
            let (result, m) = try measure(Self.noDrums(seed: seed))
            print("[Rhythm 12.5] No drums seed \(seed): \(m)")
            // Below 0.35 the Marble pulse is weighted by at most 20 %.
            XCTAssertLessThan(m.confidence, 0.35, "seed \(seed)")
            XCTAssertNotEqual(result.quality, .high, "seed \(seed)")
            let material = VisualMaterial(beatPulse: 1)
            let strongest = result.beatGrid.map { beat -> Double in
                MaterialResolver.beatPulse(material,
                                           rhythm: RhythmFrame.at(beat.time, in: result))
            }.max() ?? 0
            XCTAssertLessThanOrEqual(strongest, 0.2, "seed \(seed)")
        }
    }

    func testSilenceHasNoRhythm() throws {
        let silence = Fixture(seconds: 10)
        let result = try RhythmAnalyzer.analyze(channels: silence.channels,
                                                sampleRate: Self.sampleRate)
        XCTAssertEqual(result, RhythmAnalyzer.empty)
        XCTAssertTrue(result.beatGrid.isEmpty)
    }

    func testGenreFixturesAreDeterministic() throws {
        let fixture = Self.house(seconds: 12)
        let first = try RhythmAnalyzer.analyze(channels: fixture.channels, sampleRate: Self.sampleRate)
        let second = try RhythmAnalyzer.analyze(channels: fixture.channels, sampleRate: Self.sampleRate)
        XCTAssertEqual(first, second)
    }

    // MARK: Optional real tracks

    private struct ManifestEntry: Decodable {
        let file: String
        let bpm: Double?
        let drums: Bool?
    }

    /// Runs only when a local folder of real tracks is provided; audio is
    /// never committed. Octave errors (×2, ×½) are reported, not failed.
    func testRealTracksWhenProvided() throws {
        guard let folder = ProcessInfo.processInfo.environment["NIGHTCORE_RHYTHM_FIXTURES"],
              !folder.isEmpty else {
            throw XCTSkip("Set TEST_RUNNER_NIGHTCORE_RHYTHM_FIXTURES to a folder with manifest.json")
        }
        let root = URL(fileURLWithPath: folder, isDirectory: true)
        let entries = try JSONDecoder().decode(
            [ManifestEntry].self, from: Data(contentsOf: root.appendingPathComponent("manifest.json")))
        for entry in entries {
            let result = try RhythmAnalyzer.analyzeFile(at: root.appendingPathComponent(entry.file))
            let tempo: Double? = result.bpmCandidates.first?.bpm
            let shown: String = tempo.map { String(format: "%.1f", $0) } ?? "-"
            print("[Rhythm 12.5] \(entry.file): bpm \(shown) conf \(result.confidence) "
                  + "(\(result.quality.rawValue)) downbeat \(result.downbeatConfidence)")
            if entry.drums == false {
                XCTAssertNotEqual(result.quality, .high, entry.file)
            }
            if let expected = entry.bpm, let tempo {
                let octaves = abs(log2(tempo / expected))
                let octaveError = abs(octaves - 1) < 0.03
                XCTAssertTrue(octaves < 0.03 || octaveError, "\(entry.file): \(tempo) vs \(expected)")
            }
        }
    }
}
