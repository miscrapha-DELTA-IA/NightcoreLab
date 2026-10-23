import Foundation
import XCTest
@testable import NightcoreLab

final class SelfieVideoCaptureTests: XCTestCase {
    func testSelfieTakesUseUniqueLocalMOVPaths() {
        let directory = URL(fileURLWithPath: "/tmp/Gnarly-Capture-Fixture", isDirectory: true)
        let first = SelfieVideoCaptureFile.temporaryURL(
            directory: directory,
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!)
        let second = SelfieVideoCaptureFile.temporaryURL(
            directory: directory,
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!)
        XCTAssertEqual(first.deletingLastPathComponent(), directory)
        XCTAssertEqual(first.pathExtension, "mov")
        XCTAssertEqual(first.lastPathComponent,
                       "GNARLY-Selfie-00000000-0000-0000-0000-000000000001.mov")
        XCTAssertNotEqual(first, second)
        XCTAssertTrue(first.isFileURL)
    }

    func testActiveLyricAndEmptyGapsUseActualSourceTime() {
        let words = [WordSync(id: 1, text: "Olá", start: 10, end: 10.4,
                              spaceAfter: true),
                     WordSync(id: 2, text: "GNARLY", start: 10.4, end: 12,
                              spaceAfter: false)]
        let lines = [TimedLyricLine(id: 0, start: 10, end: 12, words: words,
                                    precision: .word)]
        XCTAssertEqual(SelfieLyricTimeline.currentText(lines: lines, at: 9.99), "")
        XCTAssertEqual(SelfieLyricTimeline.currentText(lines: lines, at: 10.5),
                       "Olá GNARLY")
        XCTAssertEqual(SelfieLyricTimeline.currentText(lines: lines, at: 13), "")
    }

    func testRecordedCueListOnlyStoresChangesAndClearsAfterVerse() {
        var cues: [SelfieLyricCue] = []
        SelfieLyricTimeline.append("Primeira", at: 0, to: &cues)
        SelfieLyricTimeline.append("Primeira", at: 0.12, to: &cues)
        SelfieLyricTimeline.append("Segunda", at: 1.5, to: &cues)
        SelfieLyricTimeline.append("", at: 2.5, to: &cues)
        XCTAssertEqual(cues.count, 3)
        XCTAssertEqual(SelfieLyricTimeline.text(at: 0.7, cues: cues), "Primeira")
        XCTAssertEqual(SelfieLyricTimeline.text(at: 1.7, cues: cues), "Segunda")
        XCTAssertEqual(SelfieLyricTimeline.text(at: 2.7, cues: cues), "")
        SelfieLyricTimeline.append("inválida", at: -.infinity, to: &cues)
        XCTAssertEqual(cues.count, 3)
    }

    @MainActor
    func testRecorderStartsWithoutRecordingOrRequestingPermissions() {
        let recorder = SelfieVideoRecorder()
        XCTAssertFalse(recorder.isReady)
        XCTAssertFalse(recorder.isRecording)
        XCTAssertFalse(recorder.isFinishing)
        XCTAssertNil(recorder.recordedURL)
        XCTAssertFalse(recorder.wasSaved)
        recorder.shutdown()
    }
}
