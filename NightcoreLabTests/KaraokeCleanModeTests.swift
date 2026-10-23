import XCTest
@testable import NightcoreLab

final class KaraokeCleanModeTests: XCTestCase {
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
        XCTAssertEqual(AppTheme.allCases.count, 18)
        XCTAssertEqual(Set(AppTheme.allCases.map(\.id)).count, 18)
        XCTAssertTrue(BackgroundStyle.allCases.contains(.marble))
        XCTAssertTrue(BackgroundStyle.allCases.contains(.cover))
        XCTAssertEqual(LyricsColorMode.allCases.count, 2)
    }

    @MainActor
    func testCleanModeDoesNotChangeLyricsOffsetOrUserPanelChoices() {
        let defaults = isolatedDefaults()
        let store = LyricsStore(offsetDefaults: defaults)
        store.userOffset = 1.5
        XCTAssertFalse(KaraokeCleanLayout.showsQuickThemeBar(cleanMode: true))
        XCTAssertEqual(store.userOffset, 1.5)
    }

    @MainActor
    func testLyricCalibrationPersistsAndScalesWithPlaybackSpeed() {
        let defaults = isolatedDefaults()
        let store = LyricsStore(offsetDefaults: defaults)
        store.userOffset = 0.2
        XCTAssertEqual(store.sourceTimelineOffset(for: FixedClock(speed: 2)), 0.4,
                       accuracy: 0.0001)
        XCTAssertEqual(LyricsStore(offsetDefaults: defaults).userOffset, 0.2,
                       accuracy: 0.0001)
    }

    func testOutputLatencyIsConvertedToSourceTimeAtDoubleSpeed() {
        XCTAssertEqual(EnginePlaybackClock.audibleSourceTime(
            anchorMedia: 10, elapsed: 0.1, speed: 2, outputLatency: 0.2),
            9.8, accuracy: 0.0001)
    }

    private func isolatedDefaults() -> UserDefaults {
        let suite = "KaraokeCleanModeTests.\(UUID().uuidString)"
        return UserDefaults(suiteName: suite)!
    }
}

private final class FixedClock: PlaybackClock, @unchecked Sendable {
    let playbackSpeed: Double
    init(speed: Double) { playbackSpeed = speed }
    var isPlaying: Bool { true }
    var lyricTime: TimeInterval { 0 }
}
