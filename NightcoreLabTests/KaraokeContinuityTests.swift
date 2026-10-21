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
