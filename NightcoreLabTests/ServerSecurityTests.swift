import Foundation
import XCTest
@testable import NightcoreLab

final class ServerSecurityTests: XCTestCase {
    func testOnlyConfiguredServerAndPrivateR2AreTrusted() {
        let server = "https://nightcorelab.onrender.com"
        let r2 = "https://0123456789abcdef0123456789abcdef.r2.cloudflarestorage.com/gnarly-cache/abcdefghijk/audio.m4a"
        XCTAssertTrue(AudioDownloadManager.isTrustedDeliveryURL(URL(string: server + "/download")!,
                                                                  serverURL: server))
        XCTAssertTrue(AudioDownloadManager.isTrustedDeliveryURL(URL(string: r2)!,
                                                                  serverURL: server))
        XCTAssertFalse(AudioDownloadManager.isTrustedDeliveryURL(
            URL(string: "http://0123456789abcdef0123456789abcdef.r2.cloudflarestorage.com/")!,
            serverURL: server))
        XCTAssertFalse(AudioDownloadManager.isTrustedDeliveryURL(
            URL(string: "https://evil.example/file")!, serverURL: server))
        XCTAssertFalse(AudioDownloadManager.isTrustedDeliveryURL(
            URL(string: "https://nightcorelab.onrender.com.evil.example/download")!,
            serverURL: server))
    }

    func testYouTubeLinksBecomeCanonicalHTTPS() {
        let url = AudioDownloadManager.youtubeVideoURL(from: "https://youtu.be/abcdefghijk?feature=share")
        XCTAssertEqual(url?.absoluteString, "https://www.youtube.com/watch?v=abcdefghijk")
    }
}
