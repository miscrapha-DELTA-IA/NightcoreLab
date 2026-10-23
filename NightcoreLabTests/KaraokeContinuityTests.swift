import XCTest
import UIKit
@testable import NightcoreLab

final class KaraokeContinuityTests: XCTestCase {
    private var lines: [TimedLyricLine] {
        (0..<4).map { index in
            let start = Double(index) * 2
            return TimedLyricLine(id: index, start: start, end: start + 2,
                words: [WordSync(id: 0, text: "Cantar", start: start, end: start + 2, spaceAfter: false)], precision: .word)
        }
    }
    private let voice = KaraokeVoiceFrame(rms: 0.2, frequency: 220, confidence: 0.95)

    @MainActor
    func testSessionPreservesScoreComboAndAccuracyAcrossForwardAndBackwardSeeks() {
        let session = KaraokeScoringSession()
        session.present(true); session.start(mode: .microphone, lines: lines, at: 0)
        session.microphoneFrame = { _ in self.voice }
        for i in 1...40 { session.advance(time: Double(i) / 20, playing: true, lines: lines) }
        let before = session.snapshot
        XCTAssertGreaterThan(before.totalScore, 0)
        session.advance(time: 6, playing: true, lines: lines)
        XCTAssertEqual(session.snapshot.totalScore, before.totalScore)
        XCTAssertEqual(session.snapshot.bestCombo, before.bestCombo)
        XCTAssertEqual(session.snapshot.accuracyPercentage, before.accuracyPercentage)
        session.advance(time: 0, playing: true, lines: lines)
        for i in 1...40 { session.advance(time: Double(i) / 20, playing: true, lines: lines) }
        XCTAssertEqual(session.snapshot.totalScore, before.totalScore, "Replaying a scored phrase must not farm points")
        XCTAssertEqual(session.snapshot.judgedVerses, before.judgedVerses)
        session.advance(time: 4, playing: true, lines: lines)
        for i in 81...120 { session.advance(time: Double(i) / 20, playing: true, lines: lines) }
        XCTAssertGreaterThan(session.snapshot.totalScore, before.totalScore, "Unvisited passages still score")
        session.resetForTrack()
        XCTAssertEqual(session.snapshot.totalScore, 0)
        XCTAssertNil(session.lastResult)
    }

    func testReturningToPreviouslySkippedVerseScoresItOnceWithoutDoubleJudging() {
        var engine = KaraokeScoringEngine()
        engine.start(lines: lines, at: 0)
        for i in 1...20 { engine.advance(to: Double(i) / 20, voice: voice, playing: true) }
        let first = engine.snapshot.totalScore
        engine.seek(to: 4)
        for i in 81...120 { engine.advance(to: Double(i) / 20, voice: voice, playing: true) }
        let afterLaterVerse = engine.snapshot.totalScore
        XCTAssertGreaterThan(afterLaterVerse, first)
        engine.seek(to: 2)
        for i in 41...80 { engine.advance(to: Double(i) / 20, voice: voice, playing: true) }
        XCTAssertGreaterThan(engine.snapshot.totalScore, afterLaterVerse)
        let earned = engine.snapshot
        engine.seek(to: 2)
        for i in 41...80 { engine.advance(to: Double(i) / 20, voice: voice, playing: true) }
        XCTAssertEqual(engine.snapshot.totalScore, earned.totalScore)
        XCTAssertEqual(engine.snapshot.judgedVerses, earned.judgedVerses)
        engine.finish()
        XCTAssertTrue(engine.snapshot.isFinished)
    }

    @MainActor
    func testExplicitShortSeekDoesNotAwardPointsForTheSkippedGap() {
        let session = KaraokeScoringSession()
        session.present(true); session.start(mode: .microphone, lines: lines, at: 0)
        session.microphoneFrame = { _ in self.voice }
        for i in 1...8 { session.advance(time: Double(i) / 20, playing: true, lines: lines) }
        let earned = session.snapshot.totalScore
        session.seek(to: 0.7)
        XCTAssertEqual(session.snapshot.totalScore, earned)
        session.advance(time: 0.75, playing: true, lines: lines)
        session.advance(time: 0.8, playing: true, lines: lines)
        XCTAssertLessThanOrEqual(session.snapshot.totalScore - earned, 11)
        XCTAssertGreaterThan(session.snapshot.totalScore, earned)
    }

    func testLongFinalWordAcceptsQuietRealVoiceWithoutScoringSilence() {
        let line = TimedLyricLine(id: 0, start: 0, end: 2, words: [
            WordSync(id: 0, text: "AMOR", start: 0, end: 2, spaceAfter: false)
        ], precision: .word)
        var engine = KaraokeScoringEngine()
        engine.start(lines: [line], at: 0)
        for step in 1...25 {
            engine.advance(to: Double(step) * 0.05, voice: voice, playing: true)
        }
        let beforeSoft = engine.snapshot.totalScore
        let quietButPitched = KaraokeVoiceFrame(rms: 0.05, frequency: 220, confidence: 0.60)
        XCTAssertFalse(quietButPitched.isVoiced, "This must exercise the limited soft-tail grace")
        engine.advance(to: 1.30, voice: quietButPitched, playing: true)
        XCTAssertGreaterThan(engine.snapshot.totalScore, beforeSoft)
        let afterSoft = engine.snapshot.totalScore

        engine.advance(to: 1.35, voice: .silence, playing: true)
        XCTAssertEqual(engine.snapshot.totalScore, afterSoft,
                       "True silence never earns sustained-note points")
        engine.advance(to: 1.40, voice: quietButPitched, playing: true)
        XCTAssertEqual(engine.snapshot.totalScore, afterSoft,
                       "A quiet frame must not resurrect a vocal after silence")
    }

    func testSoftGraceDoesNotApplyToShortWordsOrAfterSeek() {
        let shortLine = TimedLyricLine(id: 0, start: 0, end: 0.7, words: [
            WordSync(id: 0, text: "SOL", start: 0, end: 0.7, spaceAfter: false)
        ], precision: .word)
        let soft = KaraokeVoiceFrame(rms: 0.05, frequency: 220, confidence: 0.60)
        var short = KaraokeScoringEngine()
        short.start(lines: [shortLine], at: 0)
        for step in 1...10 { short.advance(to: Double(step) * 0.05, voice: voice, playing: true) }
        let shortScore = short.snapshot.totalScore
        short.advance(to: 0.55, voice: soft, playing: true)
        XCTAssertEqual(short.snapshot.totalScore, shortScore)

        let longLine = TimedLyricLine(id: 0, start: 0, end: 2, words: [
            WordSync(id: 0, text: "LONGO", start: 0, end: 2, spaceAfter: false)
        ], precision: .word)
        var afterSeek = KaraokeScoringEngine()
        afterSeek.start(lines: [longLine], at: 0)
        for step in 1...25 {
            afterSeek.advance(to: Double(step) * 0.05, voice: voice, playing: true)
        }
        let scoreBeforeSeek = afterSeek.snapshot.totalScore
        afterSeek.seek(to: 1.30)
        afterSeek.advance(to: 1.35, voice: soft, playing: true)
        XCTAssertEqual(afterSeek.snapshot.totalScore, scoreBeforeSeek)
    }

    func testHeldEndingWidensPitchToleranceOnlyWhenRequested() throws {
        let key = KeyAnalysisResult(hypotheses: [
            KeyHypothesis(tonic: .c, scale: .major, confidence: 0.95)
        ], provenance: ExpressionProvenance(method: "fixture",
            fingerprint: ExpressionFingerprint(algorithmVersion: 1),
            analyzedThrough: 2, confidence: 0.95))
        // A vibrato peak 0.56 semitones away from A4 in the C major scale.
        let frequency = 440 * pow(2, 0.56 / 12)
        let ordinary = try XCTUnwrap(KaraokeScoringEngine.harmonicAccuracy(
            frequency: frequency, key: key))
        let sustained = try XCTUnwrap(KaraokeScoringEngine.harmonicAccuracy(
            frequency: frequency, key: key, sustainedTail: true))
        XCTAssertEqual(ordinary, 1 - (0.56 - 0.35) / 0.75, accuracy: 0.005)
        XCTAssertEqual(sustained, 1, accuracy: 0.005)
        XCTAssertGreaterThan(sustained, ordinary)
        XCTAssertNil(KaraokeScoringEngine.harmonicAccuracy(frequency: 440, key: nil,
                                                           sustainedTail: true),
                     "Missing key analysis must never become fabricated pitch evidence")
    }

    @MainActor
    func testResultCaptureUsesVisibleViewAndDisplayScale() async throws {
        let windows = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows)
        let window = try XCTUnwrap(windows.first(where: { !$0.isHidden }))
        let view = UIView(frame: CGRect(x: 0, y: 0, width: 160, height: 240))
        view.backgroundColor = .magenta
        window.addSubview(view)
        defer { view.removeFromSuperview() }
        view.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(150))
        let image = try KaraokeResultCapture.image(of: view, scale: 2)
        XCTAssertEqual(image.size, view.bounds.size)
        XCTAssertEqual(image.cgImage?.width, Int(view.bounds.width * 2))
        XCTAssertEqual(image.cgImage?.height, Int(view.bounds.height * 2))
        XCTAssertThrowsError(try KaraokeResultCapture.image(of: UIView(), scale: 2))
    }
}
