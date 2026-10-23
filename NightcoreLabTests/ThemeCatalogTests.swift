import XCTest
import SwiftUI
import UIKit
@testable import NightcoreLab

final class ThemeCatalogTests: XCTestCase {
    private func luminance(_ color: Color) -> Double {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        UIColor(color).getRed(&r, green: &g, blue: &b, alpha: &a)
        func lin(_ c: CGFloat) -> Double {
            let v = Double(c)
            return v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * lin(r) + 0.7152 * lin(g) + 0.0722 * lin(b)
    }

    func testThemeCatalogContainsEighteenThemes() {
        XCTAssertEqual(AppTheme.allCases.count, 27)
        XCTAssertEqual(MarbleTheme.allCases.count, 27)
        XCTAssertEqual(AppTheme.noir.next, .ultrapink)
        XCTAssertEqual(AppTheme.ultrablack.next, .gnarly)
        XCTAssertEqual(AppTheme.gnarly.next, .xeroxSerpentine)
        XCTAssertEqual(AppTheme.gnarlyOrganism.next, .acid)
    }

    func testNamesAndDominantColorsAreUnique() {
        let names = AppTheme.allCases.map(\.displayName)
        let dominant = AppTheme.allCases.map(\.dominantColorName)
        XCTAssertEqual(Set(names).count, AppTheme.allCases.count)
        XCTAssertEqual(Set(dominant).count, AppTheme.allCases.count)
        XCTAssertFalse(dominant.contains(where: \.isEmpty))
    }

    /// O botão de raio percorre cada tema exatamente uma vez.
    func testBoltCycleVisitsEveryThemeOnce() {
        var seen: [AppTheme] = []
        var theme = AppTheme.allCases[0]
        for _ in AppTheme.allCases {
            seen.append(theme)
            theme = theme.next
        }
        XCTAssertEqual(Set(seen).count, AppTheme.allCases.count)
        XCTAssertEqual(theme, AppTheme.allCases[0])
    }

    /// Texto preto sobre o acento deve manter contraste WCAG AA (4,5:1).
    func testOnAccentKeepsAAContrast() {
        let black = luminance(.black)
        for theme in AppTheme.allCases {
            let ratio = (luminance(theme.accent) + 0.05) / (black + 0.05)
            XCTAssertGreaterThanOrEqual(ratio, 4.5, "\(theme.displayName): \(ratio)")
        }
    }

    func testEveryThemeHasKaraokeAndFluidPalettes() {
        for theme in AppTheme.allCases {
            XCTAssertEqual(KaraokeTheme.forAppTheme(theme), MarbleTheme(appTheme: theme).karaoke)
            XCTAssertEqual(TurbulentPalette.colors(for: theme).count, 4)
        }
    }
}
