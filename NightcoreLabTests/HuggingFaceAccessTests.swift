import Foundation
import XCTest
@testable import NightcoreLab

final class HuggingFaceAccessTests: XCTestCase {
    func testOnlyExplicitFreePersonalReadIdentityIsAccepted() throws {
        func profile(pro: Bool? = false, role: String = "read") throws -> Data {
            var value: [String: Any] = ["name": "free-listener", "auth": ["accessToken": ["role": role]]]
            if let pro { value["isPro"] = pro }
            return try JSONSerialization.data(withJSONObject: value)
        }
        XCTAssertEqual(try HuggingFaceAccess.freeProfile(profile()).name, "free-listener")
        XCTAssertThrowsError(try HuggingFaceAccess.freeProfile(profile(pro: true)))
        XCTAssertThrowsError(try HuggingFaceAccess.freeProfile(profile(pro: nil)))
        XCTAssertThrowsError(try HuggingFaceAccess.freeProfile(profile(role: "write")))
        XCTAssertThrowsError(try HuggingFaceAccess.freeProfile(profile(role: "fineGrained")))
    }
    func testPersonalTokenCannotLeakToRenderOrResponseSelectedHost() throws {
        let token = "hf_this_is_a_synthetic_read_token"
        let allowed = URLRequest(url: CloudStemWorker.communityURL.appendingPathComponent("gradio_api/call/separate"))
        XCTAssertEqual(try HuggingFaceAccess.authorize(allowed, token: token).value(forHTTPHeaderField: "Authorization"), "Bearer " + token)
        for url in ["https://nightcorelab.onrender.com/v1/stems/cloud/ticket",
                    "https://d-r-e-audio-separator.hf.space.attacker.test/gradio_api/file=x",
                    "http://d-r-e-audio-separator.hf.space/gradio_api/upload",
                    "https://other.hf.space/gradio_api/call/separate"] {
            XCTAssertThrowsError(try HuggingFaceAccess.authorize(URLRequest(url: URL(string: url)!), token: token))
        }
        XCTAssertNil(try HuggingFaceAccess.authorize(URLRequest(url: URL(string: "https://backend.invalid")!), token: "").value(forHTTPHeaderField: "Authorization"))
    }
}
