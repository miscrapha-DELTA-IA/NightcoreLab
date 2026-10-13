import Foundation
import SwiftUI
import XCTest
@testable import NightcoreLab

final class KaraokeExperienceTests: XCTestCase {
    func testSpotlightIsDefaultAndCodable() throws {
        let style = KaraokeFocusMode.spotlight
        XCTAssertEqual(KaraokeFocusMode.allCases, [.spotlight, .classic])
        XCTAssertEqual(KaraokeFocusMode.storageKey, "karaokeFocusMode")
        let encoded = try JSONEncoder().encode(style)
        XCTAssertEqual(try JSONDecoder().decode(KaraokeFocusMode.self, from: encoded), style)
    }

    func testFocusPreferenceSurvivesReopeningDefaults() throws {
        let suite = "nightcore.karaoke-focus.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertEqual(
            KaraokeFocusMode(rawValue: defaults.string(forKey: KaraokeFocusMode.storageKey) ?? "spotlight"),
            .spotlight
        )
        defaults.set(KaraokeFocusMode.classic.rawValue, forKey: KaraokeFocusMode.storageKey)
        let reopened = try XCTUnwrap(UserDefaults(suiteName: suite))
        XCTAssertEqual(
            KaraokeFocusMode(rawValue: reopened.string(forKey: KaraokeFocusMode.storageKey) ?? ""),
            .classic
        )
    }

    func testActiveLineHasPriorityAndNeighborsFadeGradually() {
        let active = KaraokeFocusResolver.emphasis(lineID: 3, activeID: 3, mode: .spotlight)
        let next = KaraokeFocusResolver.emphasis(lineID: 4, activeID: 3, mode: .spotlight)
        let farther = KaraokeFocusResolver.emphasis(lineID: 5, activeID: 3, mode: .spotlight)
        let distant = KaraokeFocusResolver.emphasis(lineID: 12, activeID: 3, mode: .spotlight)
        XCTAssertTrue(active.showsIndicator)
        XCTAssertFalse(next.showsIndicator)
        XCTAssertEqual(active.opacity, 1)
        XCTAssertGreaterThan(active.opacity, next.opacity)
        XCTAssertGreaterThan(next.opacity, farther.opacity)
        XCTAssertGreaterThan(farther.opacity, distant.opacity)
        XCTAssertEqual(next, KaraokeFocusResolver.emphasis(
            lineID: 2, activeID: 3, mode: .spotlight))
        XCTAssertEqual(farther, KaraokeFocusResolver.emphasis(
            lineID: 1, activeID: 3, mode: .spotlight))
    }

    func testClassicModeKeepsAllLinesAtOriginalPresentation() {
        for id in 0..<20 {
            let emphasis = KaraokeFocusResolver.emphasis(
                lineID: id, activeID: 8, mode: .classic)
            XCTAssertEqual(emphasis.opacity, 1)
            XCTAssertEqual(emphasis.scale, 1)
            XCTAssertFalse(emphasis.showsIndicator)
        }
        let unknown = KaraokeFocusResolver.emphasis(
            lineID: 10, activeID: nil, mode: .spotlight)
        XCTAssertEqual(unknown.opacity, 1)
        XCTAssertEqual(unknown.scale, 1)
    }

    func testScrollInsetIsBoundedForSmallAndLargeDevices() {
        let narrow = KaraokeFocusResolver.scrollInset(for: 320)
        let tall = KaraokeFocusResolver.scrollInset(for: 960)
        XCTAssertGreaterThanOrEqual(narrow, 95)
        XCTAssertLessThanOrEqual(tall, 340)
        XCTAssertGreaterThan(tall, narrow)
        XCTAssertEqual(KaraokeFocusResolver.scrollInset(for: 0), 95)
    }

    func testAutomaticScrollSkipsDuplicateAndLongJump() {
        let lines = lineFixture(starts: [0, 1.2, 2.4, 3.6])
        XCTAssertNil(KaraokeScrollPolicy.decision(
            lines: lines, targetID: 1, lastRequestedID: 1, reason: .automatic,
            reduceMotion: false, allowsDecorativeMotion: true))
        let jump = KaraokeScrollPolicy.decision(
            lines: lines, targetID: 3, lastRequestedID: 0, reason: .automatic,
            reduceMotion: false, allowsDecorativeMotion: true)
        XCTAssertEqual(jump?.duration, 0)
    }

    func testFastVersesScrollInstantlyAtAnyPlaybackRate() {
        // Fixture uses source-time starts, valid at 0.5x, 1x, 1.5x or 2x.
        let lines = lineFixture(starts: [0, 0.18, 0.36, 0.54, 0.72])
        for i in 1..<lines.count {
            let decision = KaraokeScrollPolicy.decision(
                lines: lines, targetID: i, lastRequestedID: i - 1,
                reason: .automatic, reduceMotion: false,
                allowsDecorativeMotion: true)
            XCTAssertEqual(decision?.duration, 0)
        }
    }

    func testNormalVerseScrollIsBoundedAndInterruptibleBySeek() {
        let lines = lineFixture(starts: [0, 1.8, 3.6])
        let follow = KaraokeScrollPolicy.decision(
            lines: lines, targetID: 1, lastRequestedID: 0, reason: .automatic,
            reduceMotion: false, allowsDecorativeMotion: true)
        XCTAssertEqual(follow?.duration, 0.16)
        let seek = KaraokeScrollPolicy.decision(
            lines: lines, targetID: 0, lastRequestedID: 1, reason: .seek,
            reduceMotion: false, allowsDecorativeMotion: true)
        XCTAssertEqual(seek?.duration, 0)
        let resume = KaraokeScrollPolicy.decision(
            lines: lines, targetID: 2, lastRequestedID: nil, reason: .returnToLive,
            reduceMotion: false, allowsDecorativeMotion: true)
        XCTAssertEqual(resume?.duration, 0)
    }

    func testReduceMotionAndEnergySuspensionDisableScrollAnimation() {
        let lines = lineFixture(starts: [0, 2])
        for reduceMotion in [false, true] {
            for allowed in [false, true] {
                let decision = KaraokeScrollPolicy.decision(
                    lines: lines, targetID: 1, lastRequestedID: 0,
                    reason: .automatic, reduceMotion: reduceMotion,
                    allowsDecorativeMotion: allowed)
                XCTAssertEqual(decision?.animated, allowed && !reduceMotion)
            }
        }
    }

    private func lineFixture(starts: [TimeInterval]) -> [TimedLyricLine] {
        starts.enumerated().map { index, start in
            TimedLyricLine(id: index, start: start,
                           end: start + 0.16, words: [
                            WordSync(id: 0, text: "WORD", start: start,
                                     end: start + 0.16, spaceAfter: false)
                           ], precision: .word)
        }
    }

    func testPresentationDoesNotModifyExistingWordClockOrPrecision() {
        let word = WordSync(id: 0, text: "Hello", start: 4, end: 6, spaceAfter: false)
        let timed = TimedLyricLine(id: 3, start: 4, end: 6, words: [word], precision: .word)
        _ = KaraokeFocusResolver.emphasis(lineID: timed.id, activeID: 3, mode: .spotlight)
        XCTAssertEqual(word.progress(at: 4), 0)
        XCTAssertEqual(word.progress(at: 5), 0.5)
        XCTAssertEqual(word.progress(at: 6), 1)
        if case .line = timed.precision {
            XCTFail("Focus presentation must not alter precision")
        }
    }
}
