import Foundation
import SwiftUI
import UIKit
import XCTest
@testable import NightcoreLab

final class KaraokeTypographyTests: XCTestCase {
    func testASSKaraokeParserAndContinuousFill() throws {
        let ass = "Dialogue: 0,0:00:02.00,0:00:04.00,Default,,0,0,0,,{\\k50}He {\\kf75}llo {\\ko25}world"
        let output = ASSKaraokeParser.parse(ass)
        let line = try XCTUnwrap(output.lines.first)
        XCTAssertEqual(line.provenance, .assKaraoke)
        XCTAssertEqual(line.words.count, 3)
        XCTAssertEqual(line.words[1].start, 2.5, accuracy: 0.001)
        XCTAssertEqual(line.words[1].progressFill(at: 2.875), 0.5, accuracy: 0.001)
        XCTAssertEqual(line.words[2].progressFill(at: 3.125), 1)
        XCTAssertEqual(line.words[0].progressFill(at: 1.99), 0)
    }

    func testEstimatedAlignmentIsMonotonicAndWithinLine() {
        let words = ["Canta", "comigo", "agora"].enumerated().map {
            WordSync(id: $0.offset, text: $0.element, start: 2, end: 4,
                     spaceAfter: $0.offset < 2)
        }
        let line = TimedLyricLine(id: 0, start: 2, end: 4, words: words,
                                  precision: .line)
        let refined = LyricsAlignmentRefiner.refine([line], onsets: [2.51, 3.26])[0]
        XCTAssertEqual(refined.precision, .estimated)
        XCTAssertEqual(refined.provenance, .estimatedRefined)
        XCTAssertEqual(refined.words[1].start, 2.51, accuracy: 0.18)
        XCTAssertTrue(zip(refined.words, refined.words.dropFirst()).allSatisfy {
            $0.0.start < $0.1.start && $0.0.end <= $0.1.start + 0.01
        })
        XCTAssertEqual(refined.words.last?.end, 4)
    }

    func testMultilingualFontCascadeContainsCJKArabicAndEmoji() {
        let descriptor = TypographyFont.cascaded(.systemFont(ofSize: 24)).fontDescriptor
        let cascade = descriptor.object(forKey: .cascadeList) as? [UIFontDescriptor]
        XCTAssertEqual(cascade?.count, 3)
    }

    private func word(_ text: String = "HEART", id: Int = 2) -> WordSync {
        WordSync(id: id, text: text, start: 2, end: 4, spaceAfter: true)
    }

    func testSelectionIsCodableAndPersistsAcrossDefaultsReopen() throws {
        XCTAssertEqual(TypographyStyle.allCases,
                       [.neon, .magazineCutout, .glitch, .kinetic, .minimal,
                        .vinylSticker, .dymoTicket, .liquidCapsule])
        let suite = "nightcore.typography.\(UUID().uuidString)"
        guard let first = UserDefaults(suiteName: suite) else {
            return XCTFail("Missing isolated defaults")
        }
        defer { first.removePersistentDomain(forName: suite) }
        XCTAssertEqual(TypographyStyle(
            rawValue: first.string(forKey: TypographyStyle.storageKey) ?? "neon"), .neon)
        first.set(TypographyStyle.magazineCutout.rawValue,
                  forKey: TypographyStyle.storageKey)

        let reopened = try XCTUnwrap(UserDefaults(suiteName: suite))
        let persisted = try XCTUnwrap(reopened.string(forKey: TypographyStyle.storageKey))
        XCTAssertEqual(TypographyStyle(rawValue: persisted), .magazineCutout)
        let data = try JSONEncoder().encode(TypographyStyle.magazineCutout)
        XCTAssertEqual(try JSONDecoder().decode(TypographyStyle.self, from: data),
                       .magazineCutout)
    }

    func testObjectModelsHaveDistinctStablePhysicalParametersAndFill() throws {
        let styles: [TypographyStyle] = [.vinylSticker, .dymoTicket, .liquidCapsule]
        let seed = TypographyResolver.stableSeed(lineID: 4, word: word())
        let appearances = try styles.map { style in
            try XCTUnwrap(ObjectWordStyleResolver.resolve(
                style: style, seed: seed, progress: 0.4))
        }
        XCTAssertEqual(Set(appearances.map(\.material)).count, 3)
        XCTAssertEqual(Set(appearances.map(\.borderWidth)).count, 3)
        XCTAssertEqual(Set(appearances.map(\.shadowRadius)).count, 3)
        for (style, appearance) in zip(styles, appearances) {
            XCTAssertEqual(appearance.fill, 0.4)
            XCTAssertEqual(appearance, ObjectWordStyleResolver.resolve(
                style: style, seed: seed, progress: 0.4))
            XCTAssertEqual(ObjectWordStyleResolver.resolve(
                style: style, seed: seed, progress: -1)?.fill, 0)
            XCTAssertEqual(ObjectWordStyleResolver.resolve(
                style: style, seed: seed, progress: 2)?.fill, 1)
        }
        XCTAssertNil(ObjectWordStyleResolver.resolve(
            style: .magazineCutout, seed: seed, progress: 0.4))
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
