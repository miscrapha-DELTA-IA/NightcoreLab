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
