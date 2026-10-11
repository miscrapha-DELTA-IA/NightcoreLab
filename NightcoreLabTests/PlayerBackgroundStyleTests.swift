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
