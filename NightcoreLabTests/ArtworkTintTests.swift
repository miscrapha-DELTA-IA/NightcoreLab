import XCTest
@testable import NightcoreLab

final class ArtworkTintTests: XCTestCase {
    private func pixels(_ red: UInt8, _ green: UInt8, _ blue: UInt8) -> [UInt8] {
        Array(repeating: [red, green, blue, 255], count: 24 * 24).flatMap { $0 }
    }

    func testRedCoverProducesRedHue() throws {
        let hue = try XCTUnwrap(ArtworkTintExtractor.dominantHue(in: pixels(255, 0, 0)))
        XCTAssertLessThan(min(hue, 1 - hue), 0.04)
    }

    func testBlueCoverProducesBlueHue() throws {
        let hue = try XCTUnwrap(ArtworkTintExtractor.dominantHue(in: pixels(0, 0, 255)))
        XCTAssertEqual(hue, 2.0 / 3.0, accuracy: 0.04)
    }

    func testMonochromeCoverUsesThemeFallback() {
        XCTAssertNil(ArtworkTintExtractor.dominantHue(in: pixels(125, 125, 125)))
        XCTAssertNil(ArtworkTintExtractor.dominantHue(in: []))
    }

    func testTransparentPixelsAreIgnored() {
        let transparentPixel: [UInt8] = [255, 0, 0, 0]
        let rgba = Array(repeating: transparentPixel, count: 24 * 24)
            .flatMap { $0 }
        XCTAssertNil(ArtworkTintExtractor.dominantHue(in: rgba))
    }

    func testArtworkHueKeepsValidRange() {
        let data = pixels(19, 230, 121)
        let hue = ArtworkTintExtractor.dominantHue(in: data)
        XCTAssertNotNil(hue)
        XCTAssertTrue((0..<1).contains(hue ?? -1))
    }
}
