import XCTest
@testable import NightcoreLab

final class KaraokeCleanModeTests: XCTestCase {
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
        let store = LyricsStore()
        store.userOffset = 1.5
        XCTAssertFalse(KaraokeCleanLayout.showsQuickThemeBar(cleanMode: true))
        XCTAssertEqual(store.userOffset, 1.5)
    }
}
