import XCTest
import Foundation
@testable import NightcoreLab

final class GnarlyThemeEngineTests: XCTestCase {
    private func base(_ time: Double = 0) -> MaterialFrame {
        MaterialResolver.resolve(.legacyMarble, timestamp: time)
    }

    func testFirstFifthUsesCoverHueBeforeFullSpectrumMix() {
        let warm = GnarlyThemeEngine.sample(sourceTime: 18, duration: 100,
                                           artworkHue: 0.04, base: base(18))
        let cool = GnarlyThemeEngine.sample(sourceTime: 18, duration: 100,
                                           artworkHue: 0.59, base: base(18))
        XCTAssertTrue(warm.albumPhase)
        XCTAssertTrue(cool.albumPhase)
        XCTAssertNotEqual(warm.colors, cool.colors)
        let boundary = GnarlyThemeEngine.sample(sourceTime: 20, duration: 100,
                                                artworkHue: 0.04, base: base(20))
        XCTAssertTrue(boundary.albumPhase)
        let full = GnarlyThemeEngine.sample(sourceTime: 38, duration: 100,
                                            artworkHue: 0.04, base: base(38))
        XCTAssertFalse(full.albumPhase)
        XCTAssertNotEqual(full.colors, boundary.colors)
        XCTAssertEqual(full.colors.count, 5)
        XCTAssertTrue(full.frame.parameters.usesProceduralTexture)
        XCTAssertTrue(MarbleSurfaceBinding.resolve(frame: full.frame).textured)
    }

    func testSeekOrderDoesNotChangeAnyGnarlyFrame() {
        let stamps: [Double] = [0, 11, 20, 22, 28, 77, 168, 206, 241]
        let forward = stamps.map {
            GnarlyThemeEngine.sample(sourceTime: $0, duration: 241,
                                     artworkHue: 0.73, base: base($0))
        }
        let reversed = stamps.reversed().map {
            GnarlyThemeEngine.sample(sourceTime: $0, duration: 241,
                                     artworkHue: 0.73, base: base($0))
        }.reversed()
        for (left, right) in zip(forward, reversed) {
            XCTAssertEqual(left.colors, right.colors)
            XCTAssertEqual(left.frame, right.frame)
        }
    }

    func testCoverTransitionIsContinuousAndAllValuesAreBounded() {
        for t in stride(from: 19.8, through: 28.2, by: 0.25) {
            let sample = GnarlyThemeEngine.sample(sourceTime: t, duration: 100,
                                                 artworkHue: 0.1, base: base(t))
            XCTAssertEqual(sample.colors.count, 5)
            for color in sample.colors {
                XCTAssertTrue(color.red.isFinite && (0...1).contains(color.red))
                XCTAssertTrue(color.green.isFinite && (0...1).contains(color.green))
                XCTAssertTrue(color.blue.isFinite && (0...1).contains(color.blue))
            }
            XCTAssertTrue(sample.frame.parameters.usesProceduralTexture)
        }
        let before = GnarlyThemeEngine.sample(sourceTime: 20 - 0.00001, duration: 100,
                                              artworkHue: 0.1, base: base(20))
        let after = GnarlyThemeEngine.sample(sourceTime: 20 + 0.00001, duration: 100,
                                             artworkHue: 0.1, base: base(20))
        for (a, b) in zip(before.colors, after.colors) {
            XCTAssertLessThan(abs(a.red-b.red), 0.001)
            XCTAssertLessThan(abs(a.green-b.green), 0.001)
            XCTAssertLessThan(abs(a.blue-b.blue), 0.001)
        }
    }

    func testMissingCoverFallsBackWithoutGeneratingRandomColors() {
        let a = GnarlyThemeEngine.sample(sourceTime: 5, duration: 200,
                                        artworkHue: nil, base: base(5))
        let b = GnarlyThemeEngine.sample(sourceTime: 5, duration: 200,
                                        artworkHue: Double.nan, base: base(5))
        XCTAssertEqual(a.colors, b.colors)
        XCTAssertEqual(a.frame, b.frame)
    }

    func testPreviewAndMP4UseSameFrozenSourceTimeAndArtworkHue() {
        let source = GnarlyVisualContext(sourceTime: 57.25, sourceDuration: 248.0,
                                         artworkHue: 0.88)
        let preview = GnarlyThemeEngine.sample(sourceTime: source.sourceTime,
                                               duration: source.sourceDuration,
                                               artworkHue: source.artworkHue,
                                               base: base(source.sourceTime))
        let export = GnarlyThemeEngine.sample(sourceTime: source.sourceTime,
                                              duration: source.sourceDuration,
                                              artworkHue: source.artworkHue,
                                              base: base(source.sourceTime))
        XCTAssertEqual(preview.colors, export.colors)
        XCTAssertEqual(preview.frame, export.frame)
    }
}
