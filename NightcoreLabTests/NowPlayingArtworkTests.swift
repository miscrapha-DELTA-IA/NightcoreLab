import CoreImage
import MediaPlayer
import UIKit
import XCTest
@testable import NightcoreLab

@MainActor
final class NowPlayingArtworkTests: XCTestCase {
    func testCIBackedCoverBecomesRequestedBitmapArtwork() throws {
        let ciImage = CIImage(color: CIColor(red: 1, green: 0, blue: 0, alpha: 1))
            .cropped(to: CGRect(x: 0, y: 0, width: 48, height: 48))
        let artwork = try XCTUnwrap(NowPlayingArtworkLoader.artwork(UIImage(ciImage: ciImage)))
        let rendered = try XCTUnwrap(artwork.image(at: CGSize(width: 96, height: 96)))
        XCTAssertNotNil(rendered.cgImage)
        XCTAssertEqual(rendered.size, CGSize(width: 96, height: 96))
    }
}
