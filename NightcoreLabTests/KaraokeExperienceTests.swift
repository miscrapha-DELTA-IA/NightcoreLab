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
