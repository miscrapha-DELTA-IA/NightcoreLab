import XCTest
@testable import NightcoreLab

final class EnhancedLRCParserTests: XCTestCase {

    func testWordLevelWithClosingTag() {
        let raw = """
        [ar:Test]
        [00:12.00] <00:12.00> Hello <00:12.50> world <00:13.20>
        [00:15.00] <00:15.00> next <00:15.40> line
        """
        let out = EnhancedLRCParser.parse(raw)
        XCTAssertTrue(out.hasWordSync)
        XCTAssertEqual(out.lines.count, 2)

        let w = out.lines[0].words
        XCTAssertEqual(w.map(\.text), ["Hello", "world"])
        XCTAssertEqual(w[0].start, 12.0, accuracy: 0.001)
        XCTAssertEqual(w[0].end,   12.5, accuracy: 0.001)   // = início da próxima
        XCTAssertEqual(w[1].end,   13.2, accuracy: 0.001)   // = tag de fechamento
        XCTAssertEqual(w[0].progress(at: 12.25), 0.5, accuracy: 0.001)

        // última palavra sem fechamento: limitada por maxImpliedLastWord
        XCTAssertEqual(out.lines[1].words[1].end, 15.4 + EnhancedLRCParser.maxImpliedLastWord, accuracy: 0.001)
    }

    func testBackendAlignmentContractPreservesWordEndsAndPartialPlainLines() {
        let raw = """
        [00:12.00] <00:12.00> Palavra <00:12.40> <00:12.50> seguinte <00:13.20>
        [00:15.00] Outra linha incompleta
        """
        let lines = EnhancedLRCParser.parse(raw).lines
        XCTAssertEqual(lines.count, 2)
        XCTAssertEqual(lines[0].words.map(\.text), ["Palavra", "seguinte"])
        XCTAssertEqual(lines[0].words[0].end, 12.4, accuracy: 0.001)
        XCTAssertEqual(lines[0].words[1].start, 12.5, accuracy: 0.001)
        XCTAssertEqual(lines[0].words[1].end, 13.2, accuracy: 0.001)
        XCTAssertEqual(lines[1].precision, .line)
        XCTAssertEqual(lines[1].text.trimmingCharacters(in: .whitespaces), "Outra linha incompleta")
    }

    func testSyllablesGluedAndPlainLineFallback() {
        let raw = """
        [00:01.00]<00:01.00>Hel<00:01.30>lo <00:01.60>you
        [00:05.00]plain line without word tags
        """
        let out = EnhancedLRCParser.parse(raw)
        XCTAssertEqual(out.lines[0].words.map(\.spaceAfter), [false, true, false])
        XCTAssertEqual(out.lines[0].text, "Hello you")
        XCTAssertEqual(out.lines[1].precision, .line)
    }

    func testOffsetAndActiveIndex() {
        let raw = "[offset:500]\n[00:10.00]<00:10.00>a <00:10.50>b"
        let out = EnhancedLRCParser.parse(raw)
        XCTAssertEqual(out.lines[0].start, 9.5, accuracy: 0.001)
        XCTAssertNil(out.lines.activeIndex(at: 1))
        XCTAssertEqual(out.lines.activeIndex(at: 9.6), 0)
    }
}
