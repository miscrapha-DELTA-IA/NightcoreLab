import XCTest
@testable import NightcoreLab

final class LRCParserTests: XCTestCase {
    func testParsesAndSortsTimestampedLines() {
        let lyrics = """
        [ar:Test Artist]
        [00:12.50] First line
        [00:03.125] Before
        [01:02.05] Last line
        """
        let lines = LRCParser.parse(lyrics)
        XCTAssertEqual(lines.map(\.text), ["Before", "First line", "Last line"])
        XCTAssertEqual(lines[0].time, 3.125, accuracy: 0.0001)
        XCTAssertEqual(lines[1].time, 12.5, accuracy: 0.0001)
        XCTAssertEqual(lines[2].time, 62.05, accuracy: 0.0001)
    }

    func testMultipleTimestampsAndEmptyInstrumentalLine() {
        let lines = LRCParser.parse("[00:01.00][00:03.25] Chorus\n[00:05.00] ")
        XCTAssertEqual(lines.count, 3)
        XCTAssertEqual(lines.map(\.text), ["Chorus", "Chorus", ""])
    }

    func testSkipsInvalidTimestampsAndMetadata() {
        let lines = LRCParser.parse("[ti:Title]\n[00:65.00]Invalid\n[00:02.30]Valid")
        XCTAssertEqual(lines.count, 1)
        XCTAssertEqual(lines[0].text, "Valid")
    }
}
