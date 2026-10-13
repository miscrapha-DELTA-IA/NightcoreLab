import Foundation
import SwiftUI
import XCTest
@testable import NightcoreLab

final class CreatorPresetSharingTests: XCTestCase {
    private func samplePreset() -> CreatorPreset {
        var controls = CreatorControls()
        controls.set(0.73, for: .distortion)
        controls.set(0.84, for: .glow)
        return CreatorPreset(
            experienceID: "cyber-night",
            materialID: "liquid-glass",
            typography: TypographyPreset(style: .magazineCutout,
                                         deterministicSeed: 0xD123),
            controls: controls,
            exportProfile: ExportProfile(
                aspectRatio: .landscape, quality: .high,
                cropPolicy: .aspectFit))
    }

    private func package() throws -> CreatorPresetPackage {
        try CreatorPresetPackage(
            name: "Night Drive", author: "Creator",
            createdAt: Date(timeIntervalSince1970: 1_720_000_000),
            preset: samplePreset())
    }

    private func mutate(_ bytes: Data,
                        _ body: (inout [String: Any]) -> Void) throws -> Data {
        var json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        body(&json)
        return try JSONSerialization.data(withJSONObject: json)
    }

    private func request() throws -> StoryVideoRequest {
        let track = TrackInfo(track: Track(
            id: "12345678901", title: "Sharing Preview",
            thumbnailURL: nil, cleanArtist: "Nightcore"),
            fileName: nil, coverURL: nil)
        return try StoryRequestBuilder.make(
            mode: .player, track: track, theme: .acid,
            playerStyle: .turbulent, karaokeBackground: .marble,
            marblePhase: 1.2, playbackTime: 3,
            sourceDuration: 12, speed: 1, lines: [],
            lyricOffset: 0, typography: .classic, includeAudio: false)
    }

    func testEncodePackageAsFlatPublicJSONV1() throws {
        let bytes = try CreatorPresetSharing.jsonData(for: package())
        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        XCTAssertEqual(json["schemaVersion"] as? Int, 1)
        XCTAssertEqual(json["name"] as? String, "Night Drive")
        XCTAssertEqual(json["author"] as? String, "Creator")
        XCTAssertEqual(json["experienceID"] as? String, "cyber-night")
        XCTAssertEqual(json["materialID"] as? String, "liquid-glass")
        XCTAssertNotNil(json["typography"])
        XCTAssertNotNil(json["controls"])
        XCTAssertNotNil(json["exportProfile"])
        for privateField in ["assetID", "deviceID", "accountID", "fileURL", "localPath"] {
            XCTAssertNil(json[privateField])
        }
        XCTAssertNil(json["preset"], "v1 envelope is intentionally flat")
    }

    func testDecodeAndRoundTripEquality() throws {
        let original = try package()
        let bytes = try CreatorPresetSharing.jsonData(for: original)
        let decoded = try CreatorPresetPackageMigration.decode(bytes)
        XCTAssertEqual(decoded.package, original)
        XCTAssertEqual(decoded.package.preset, samplePreset())
        XCTAssertTrue(decoded.warnings.isEmpty)
        let second = try CreatorPresetSharing.jsonData(for: decoded.package)
        XCTAssertEqual(try CreatorPresetPackageMigration.decode(second).package, original)
    }

    func testUnknownExperienceFallsBackToOriginal() throws {
        let bytes = try mutate(CreatorPresetSharing.jsonData(for: package())) {
            $0["experienceID"] = "not-installed"
        }
        let imported = try CreatorPresetPackageMigration.decode(bytes)
        XCTAssertEqual(imported.package.preset.experienceID, "original")
        XCTAssertEqual(imported.warnings, [.experienceReplaced])
    }

    func testUnknownMaterialFallsBackToOriginalMarble() throws {
        let bytes = try mutate(CreatorPresetSharing.jsonData(for: package())) {
            $0["materialID"] = "future-super-shader"
        }
        let imported = try CreatorPresetPackageMigration.decode(bytes)
        XCTAssertEqual(imported.package.preset.materialID,
                       VisualMaterial.legacyMarble.id)
        XCTAssertEqual(imported.warnings, [.materialReplaced])
    }

    func testInvalidTypographyFallsBackToNeonWithoutChangingExportProfile() throws {
        let bytes = try mutate(CreatorPresetSharing.jsonData(for: package())) {
            var typography = $0["typography"] as? [String: Any] ?? [:]
            typography["style"] = "unknown-future-style"
            $0["typography"] = typography
        }
        let imported = try CreatorPresetPackageMigration.decode(bytes)
        XCTAssertEqual(imported.package.preset.typography.style, .neon)
        XCTAssertEqual(imported.package.preset.exportProfile,
                       samplePreset().exportProfile)
        XCTAssertEqual(imported.warnings, [.typographyReplaced])
    }

    func testUnknownExportVocabularyUsesSafeFallback() throws {
        let bytes = try mutate(CreatorPresetSharing.jsonData(for: package())) {
            var profile = $0["exportProfile"] as? [String: Any] ?? [:]
            profile["aspectRatio"] = "future-panoramic"
            profile["quality"] = "ultra-12k"
            profile["cropPolicy"] = "unsafe"
            $0["exportProfile"] = profile
        }
        let imported = try CreatorPresetPackageMigration.decode(bytes)
        XCTAssertEqual(imported.package.preset.exportProfile, ExportProfile())
        XCTAssertEqual(imported.warnings, [.exportProfileReplaced])
    }

    func testFutureSchemaIsExplicitlyRejectedWithoutMigrating() throws {
        let bytes = try mutate(CreatorPresetSharing.jsonData(for: package())) {
            $0["schemaVersion"] = 2
        }
        XCTAssertThrowsError(try CreatorPresetPackageMigration.decode(bytes)) {
            XCTAssertEqual($0 as? CreatorPresetPackageError, .unsupportedSchema(2))
        }
        XCTAssertThrowsError(try CreatorPresetPackageMigration.decode(Data("{}".utf8)))
    }

    func testInvalidControlsCannotActivateImportedPreset() throws {
        let bytes = try mutate(CreatorPresetSharing.jsonData(for: package())) {
            var controls = $0["controls"] as? [String: Any] ?? [:]
            controls["brightness"] = 4.0
            $0["controls"] = controls
        }
        XCTAssertThrowsError(try CreatorPresetPackageMigration.decode(bytes)) {
            XCTAssertEqual($0 as? CreatorPresetPackageError, .invalidPackage)
        }
    }

    func testInvalidMetadataAndOversizedFileAreRejected() throws {
        XCTAssertThrowsError(try CreatorPresetPackage(
            name: "../private/data", author: "Creator", preset: samplePreset()))
        let bytes = Data(repeating: 0x61, count: CreatorPresetSharing.maximumBytes + 1)
        XCTAssertThrowsError(try CreatorPresetPackageMigration.decode(bytes)) {
            XCTAssertEqual($0 as? CreatorPresetPackageError, .fileTooLarge)
        }
    }

    func testFileExportAndImportPreserveProfileAndMetadata() throws {
        let initial = try package()
        let url = try CreatorPresetSharing.export(initial)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        XCTAssertEqual(url.pathExtension, "json")
        let imported = try CreatorPresetSharing.importFile(at: url)
        XCTAssertEqual(imported.package, initial)
        XCTAssertEqual(imported.package.preset.exportProfile.aspectRatio, .landscape)
        XCTAssertEqual(imported.package.preset.exportProfile.quality, .high)
        XCTAssertEqual(imported.package.preset.exportProfile.cropPolicy, .aspectFit)
    }

    @MainActor
    func testImportedPreviewMatchesExistingStoryExportRenderer() throws {
        let imported = try CreatorPresetPackageMigration.decode(
            CreatorPresetSharing.jsonData(for: package()))
        let base = try request()
        let session = CreatorPresetImportSession(
            preset: imported.package.preset, source: base)
        XCTAssertEqual(session.request.layoutPolicy?.aspectRatio, .landscape)
        XCTAssertEqual(session.request.renderRuntime?.material.id, "liquid-glass")
        let canvas = StoryExportCanvas(
            request: session.request, artwork: nil,
            frame: session.frame, profile: session.profile)
        let preview = ImageRenderer(content: canvas)
        preview.proposedSize = ProposedViewSize(canvas.logicalSize)
        preview.scale = CGFloat(session.profile.width) / canvas.logicalSize.width
        let previewPixels = try XCTUnwrap(preview.uiImage?.cgImage)
        let exportPixels = try StoryFrameRenderer.render(
            request: session.request, artwork: nil,
            frame: session.frame, profile: session.profile)
        XCTAssertEqual(previewPixels.width, exportPixels.width)
        XCTAssertEqual(previewPixels.height, exportPixels.height)
        XCTAssertEqual(try XCTUnwrap(previewPixels.dataProvider?.data) as Data,
                       try XCTUnwrap(exportPixels.dataProvider?.data) as Data)
        XCTAssertNil(base.layoutPolicy, "Preview must not mutate current editor session")
    }
}
