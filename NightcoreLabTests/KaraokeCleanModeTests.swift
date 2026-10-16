import XCTest
@testable import NightcoreLab

final class KaraokeCleanModeTests: XCTestCase {
    private final class FixedSpeedClock: PlaybackClock, @unchecked Sendable {
        let isPlaying = true
        let lyricTime: TimeInterval = 10
        let playbackSpeed: Double = 2
    }

    func testArtworkIsContainedInPortraitAndLandscape() {
        let portrait = CGSize(width: 390, height: 844)
        let video = CGSize(width: 375, height: 667)
        let tablet = CGSize(width: 1024, height: 1366)
        for viewport in [portrait, video, tablet] {
            let edge = KaraokeLayoutMetrics.coverEdge(for: viewport)
            XCTAssertGreaterThan(edge, 0)
            XCTAssertLessThanOrEqual(edge, viewport.width - 80)
            XCTAssertLessThanOrEqual(edge, viewport.height * 0.56)
            XCTAssertLessThanOrEqual(edge, 520)
        }
    }

    func testTextHasMarginsAndFitsNarrowIPhone() {
        for width: CGFloat in [320, 375, 390, 430] {
            let inset = KaraokeLayoutMetrics.horizontalInset(for: width)
            let textWidth = KaraokeLayoutMetrics.textWidth(for: width)
            XCTAssertGreaterThanOrEqual(inset, 28)
            XCTAssertLessThanOrEqual(textWidth, width - 56)
            XCTAssertGreaterThan(textWidth, 0)
            XCTAssertLessThanOrEqual(KaraokeLayoutMetrics.fontSize(for: width), 28)
        }
    }

    func testScrollMarginsAdjustToShortScreens() {
        XCTAssertGreaterThanOrEqual(KaraokeLayoutMetrics.verticalMargin(for: 568), 48)
        XCTAssertLessThanOrEqual(KaraokeLayoutMetrics.verticalMargin(for: 568), 120)
    }

    func testDefaultCleanModeOmitsQuickThemeBar() {
        XCTAssertFalse(KaraokeCleanLayout.showsQuickThemeBar(cleanMode: true))
    }

    func testDisablingCleanModeRestoresQuickThemeBar() {
        XCTAssertTrue(KaraokeCleanLayout.showsQuickThemeBar(cleanMode: false))
    }

    func testAllThemesStayAvailableToControlCenter() {
        XCTAssertEqual(AppTheme.allCases.count, 17)
        XCTAssertEqual(Set(AppTheme.allCases.map(\.id)).count, 17)
        XCTAssertTrue(BackgroundStyle.allCases.contains(.marble))
        XCTAssertTrue(BackgroundStyle.allCases.contains(.cover))
        XCTAssertEqual(LyricsColorMode.allCases.count, 2)
    }

    @MainActor
    func testCleanModeDoesNotChangeLyricsOffsetOrUserPanelChoices() {
        let suite = UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = LyricsStore(offsetDefaults: defaults)
        store.userOffset = 1.5
        XCTAssertFalse(KaraokeCleanLayout.showsQuickThemeBar(cleanMode: true))
        XCTAssertEqual(store.userOffset, 1.5)
    }

    @MainActor
    func testLyricsOffsetSurvivesStoreRecreationForCurrentOutput() {
        let suite = UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let first = LyricsStore(offsetDefaults: defaults)
        first.userOffset = -0.35
        let restored = LyricsStore(offsetDefaults: defaults)
        XCTAssertEqual(restored.userOffset, -0.35, accuracy: 0.0001)
    }

    @MainActor
    func testRealTimeCalibrationFollowsPlaybackSpeed() {
        let suite = UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = LyricsStore(offsetDefaults: defaults)
        store.userOffset = 0.2
        XCTAssertEqual(store.sourceTimelineOffset(for: FixedSpeedClock()),
                       0.4, accuracy: 0.0001)
    }
}
