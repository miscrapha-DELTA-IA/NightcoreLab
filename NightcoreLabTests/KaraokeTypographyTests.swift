import Foundation
import SwiftUI
import UIKit
import XCTest
@testable import NightcoreLab

final class KaraokeTypographyTests: XCTestCase {
    private func word(_ text: String = "HEART", id: Int = 2) -> WordSync {
        WordSync(id: id, text: text, start: 2, end: 4, spaceAfter: true)
    }

    func testSelectionIsCodableAndPersistsAcrossDefaultsReopen() throws {
        XCTAssertEqual(KaraokeTypographyStyle.allCases, [.neon, .magazineCutout])
        let suite = "nightcore.typography.\(UUID().uuidString)"
        guard let first = UserDefaults(suiteName: suite) else {
            return XCTFail("Missing isolated defaults")
        }
        defer { first.removePersistentDomain(forName: suite) }
        XCTAssertEqual(KaraokeTypographyStyle(
            rawValue: first.string(forKey: KaraokeTypographyStyle.storageKey) ?? "neon"), .neon)
        first.set(KaraokeTypographyStyle.magazineCutout.rawValue,
                  forKey: KaraokeTypographyStyle.storageKey)

        let reopened = try XCTUnwrap(UserDefaults(suiteName: suite))
        let persisted = try XCTUnwrap(reopened.string(forKey: KaraokeTypographyStyle.storageKey))
        XCTAssertEqual(KaraokeTypographyStyle(rawValue: persisted), .magazineCutout)
        let data = try JSONEncoder().encode(KaraokeTypographyStyle.magazineCutout)
        XCTAssertEqual(try JSONDecoder().decode(KaraokeTypographyStyle.self, from: data),
                       .magazineCutout)
    }

    func testDeterministicIdentityAndStableMagazineAppearance() {
        let identity = "4:\(word().id):\(word().text)"
        let hash = KaraokeWordStyleResolver.deterministicHash(identity)
        XCTAssertEqual(hash, KaraokeWordStyleResolver.deterministicHash(identity))
        XCTAssertGreaterThanOrEqual(hash, 0)
        XCTAssertLessThanOrEqual(hash, 1)

        let first = KaraokeWordStyleResolver.resolve(lineID: 4, word: word())
        XCTAssertEqual(first, KaraokeWordStyleResolver.resolve(lineID: 4, word: word()))
        XCTAssertTrue((-4.0...4.0).contains(first.rotation))
        XCTAssertNotEqual(KaraokeWordStyleResolver.deterministicHash("4:2:HEART"),
                          KaraokeWordStyleResolver.deterministicHash("4:2:DREAM"))
    }

    func testMagazineVariantsAreReachableWithoutRandomness() {
        let variants = (0..<120).map {
            KaraokeWordStyleResolver.resolve(lineID: $0,
                                            word: word("word\($0)", id: $0))
        }
        XCTAssertEqual(Set(variants.map(\.font.rawValue)).count, 3)
        XCTAssertEqual(Set(variants.map(\.tone.rawValue)).count, 3)
        XCTAssertTrue(variants.allSatisfy { (-4.0...4.0).contains($0.rotation) })
    }

    private func luminance(_ color: Color) -> Double {
        let uiColor = UIColor(color)
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        XCTAssertTrue(uiColor.getRed(&r, green: &g, blue: &b, alpha: &a))
        func linear(_ component: CGFloat) -> Double {
            let c = Double(component)
            return c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(r) + 0.7152 * linear(g) + 0.0722 * linear(b)
    }

    func testMagazineForegroundHasAAContrastOnAllSeventeenThemes() {
        XCTAssertEqual(AppTheme.allCases.count, 17)
        for appTheme in AppTheme.allCases {
            let theme = KaraokeTheme.forAppTheme(appTheme)
            for tone in MagazineCutoutTone.allCases {
                let fg = luminance(tone.text)
                let bg = luminance(tone.background(theme: theme))
                let ratio = (max(fg, bg) + 0.05) / (min(fg, bg) + 0.05)
                XCTAssertGreaterThanOrEqual(ratio, 4.5,
                    "\(appTheme.displayName) with \(tone) has ratio \(ratio)")
            }
        }
        // Especially important with monochrome palettes:
        XCTAssertNotNil(KaraokeTheme.forAppTheme(.purewhite).fill)
        XCTAssertNotNil(KaraokeTheme.forAppTheme(.ultrablack).fill)
        XCTAssertNotNil(KaraokeTheme.forAppTheme(.noir).fill)
    }

    /// Verifies Neon pixel output against the exact old glyph+mask+glow path.
    @MainActor
    func testNeonRenderingMatchesOriginalForPartialWordFill() throws {
        let sample = word()
        let theme = KaraokeTheme.acid
        let fill = 0.63
        let old = LegacyNeonWord(word: sample, fill: fill, fillColor: theme.fill,
                                 glow: true, theme: theme, maxWidth: 300)
        let new = KaraokeWordView(word: sample, fill: fill,
                                  fillColor: theme.fill, glow: true, theme: theme,
                                  maxWordWidth: 300, fontSize: 30,
                                  typographyStyle: .neon, magazineAppearance: nil,
                                  isCurrentLine: true, isPastLine: false)
        func png<V: View>(_ view: V) throws -> Data {
            let renderer = ImageRenderer(content: view)
            renderer.proposedSize = ProposedViewSize(width: 300, height: 80)
            renderer.scale = 2
            return try XCTUnwrap(renderer.uiImage?.pngData())
        }
        XCTAssertEqual(try png(old), try png(new),
                       "Neon must remain pixel-equivalent to the old karaoke glyph path")
    }
}

/// A local reference to the former Neon word rendering; intentionally not
/// expressed via KaraokeWordView to catch unexpected future changes.
private struct LegacyNeonWord: View {
    let word: WordSync
    let fill: Double
    let fillColor: Color
    let glow: Bool
    let theme: KaraokeTheme
    let maxWidth: CGFloat

    private var glyph: some View {
        Text(word.text)
            .font(theme.font)
            .lineLimit(1)
            .minimumScaleFactor(0.52)
            .frame(maxWidth: maxWidth)
    }

    var body: some View {
        glyph
            .foregroundStyle(theme.inactive)
            .overlay(alignment: .leading) {
                if fill > 0 {
                    glyph
                        .foregroundStyle(fillColor)
                        .mask(alignment: .leading) {
                            Rectangle().scaleEffect(x: fill, y: 1, anchor: .leading)
                        }
                        .shadow(color: glow ? theme.glow : .clear, radius: glow ? 10 : 0)
                }
            }
    }
}
