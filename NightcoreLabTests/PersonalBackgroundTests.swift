import XCTest
import SwiftUI
import UIKit
import ImageIO
@testable import NightcoreLab

@MainActor
final class PersonalBackgroundTests: XCTestCase {
    func testSettingsAreBoundedAndDefaultDisabled() {
        let invalid = PersonalBackgroundSettings(
            enabled: true, scale: 20, offsetX: -18, offsetY: 8, dimming: 4)
        let value = invalid.normalized
        XCTAssertEqual(value.scale, 2)
        XCTAssertEqual(value.offsetX, -0.5)
        XCTAssertEqual(value.offsetY, 0.5)
        XCTAssertEqual(value.dimming, 0.75)
        XCTAssertFalse(PersonalBackgroundSettings().enabled)
    }

    func testEXIFSafeJPEGNormalizationAndMetadataFreeSnapshot() throws {
        let image = UIGraphicsImageRenderer(size: CGSize(width: 160, height: 240)).image {
            context in
            UIColor.systemPink.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 160, height: 240))
        }
        // UIGraphicsImageRenderer.size is measured in points. Its CGImage
        // dimensions are PIXELS, and Retina simulators commonly use 3x scale
        // (160x240 points -> 480x720 pixels). The production normalizer must
        // preserve pixel resolution below the 2304px cap, not shrink to points.
        let sourcePixels = try XCTUnwrap(image.cgImage)
        let data = try XCTUnwrap(image.pngData())
        let output = try XCTUnwrap(PersonalBackgroundStore.downsample(data))
        XCTAssertLessThan(output.count, 10_000_000)
        let source = try XCTUnwrap(CGImageSourceCreateWithData(output as CFData, nil))
        let frame = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        XCTAssertEqual(frame.width, sourcePixels.width)
        XCTAssertEqual(frame.height, sourcePixels.height)
        XCTAssertLessThanOrEqual(max(frame.width, frame.height), 2304)
        XCTAssertEqual(CGImageSourceGetType(source) as String?, "public.jpeg")
    }

    func testFrozenSnapshotNotMutatedBySettingsChanges() throws {
        let settings = PersonalBackgroundSettings(enabled: true)
        let captured = PersonalBackgroundSnapshot(
            id: UUID(), imageData: Data([1, 2, 3]), settings: settings)
        var updated = settings
        updated.scale = 2
        XCTAssertEqual(captured.settings.scale, 1)
        XCTAssertEqual(updated.scale, 2)
        XCTAssertEqual(captured.imageData, Data([1, 2, 3]))
    }

    func testCacheReusesSameImageAcrossStoryFrames() throws {
        let image = UIGraphicsImageRenderer(size: CGSize(width: 30, height: 30)).image {
            context in
            UIColor.red.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 30, height: 30))
        }
        let snap = PersonalBackgroundSnapshot(id: UUID(),
                imageData: try XCTUnwrap(image.jpegData(compressionQuality: 0.8)),
                settings: PersonalBackgroundSettings(enabled: true))
        let original = try XCTUnwrap(PersonalBackgroundRenderCache.image(for: snap))
        let reused = try XCTUnwrap(PersonalBackgroundRenderCache.image(for: snap))
        XCTAssertTrue(original === reused)
        PersonalBackgroundRenderCache.clear()
    }
}
