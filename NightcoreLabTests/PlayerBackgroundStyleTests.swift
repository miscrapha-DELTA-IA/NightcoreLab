import XCTest
@testable import NightcoreLab

final class PlayerBackgroundStyleTests: XCTestCase {
    func testAllBackgroundModesAreExposed() {
        XCTAssertEqual(PlayerBackgroundStyle.allCases.count, 4)
        XCTAssertEqual(PlayerBackgroundStyle.turbulent.displayName, "Turbulent Displacement")
        XCTAssertEqual(PlayerBackgroundStyle.turbulent.symbolName, "waveform.path")
    }

    func testCarouselIncludesFluidModeAndLoops() {
        XCTAssertEqual(PlayerBackgroundStyle.marquee.next, .turbulent)
        XCTAssertEqual(PlayerBackgroundStyle.turbulent.next, .blurred)
    }
}

final class MarbleThemeIntegrationTests: XCTestCase {
    func testMetalPaletteFollowsAppThemes() {
        XCTAssertEqual(MarbleTheme(appTheme: .acid), .acid)
        XCTAssertEqual(MarbleTheme(appTheme: .cyber), .cyber)
        XCTAssertEqual(MarbleTheme(appTheme: .crimson), .crimson)
        XCTAssertEqual(MarbleTheme(appTheme: .ultraviolet), .ultraviolet)
        XCTAssertEqual(MarbleTheme(appTheme: .solar), .solar)
        XCTAssertEqual(MarbleTheme(appTheme: .orchid), .orchid)
        XCTAssertEqual(MarbleTheme(appTheme: .sapphire), .sapphire)
    }

    /// Um novo AppTheme sem MarbleTheme correspondente voltaria silenciosamente ao Acid.
    func testEveryAppThemeHasItsOwnMarbleTheme() {
        XCTAssertEqual(MarbleTheme.allCases.count, AppTheme.allCases.count)
        for theme in AppTheme.allCases {
            XCTAssertEqual(MarbleTheme(appTheme: theme).rawValue, theme.rawValue,
                           "\(theme.displayName) não tem MarbleTheme correspondente")
        }
    }
}
