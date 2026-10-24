import Foundation
import Metal
import SwiftUI
import XCTest
@testable import NightcoreLab

/// Stage 71 graphics-regression contracts. This is a render-pipeline smoke
/// test, NOT a substitute for human A/B inspection on the physical iPhone.
final class Stage71MaterialVisualTests: XCTestCase {
    func testMaterialShaderHasIndependentGraphicKernelsAndCommonExportMath() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf:
            root.appendingPathComponent("NightcoreLab/Resources/CreativeUniverse.metal"),
            encoding: .utf8)
        for signature in [
            "static inline float universeFbm(",
            "static inline float2 universeAdvection(",
            "static inline float universePrintDots(",
            "static inline float universeContour(",
            "if (look == 1)", "else if (look == 7)", "else if (look == 8)",
            "else if (look == 9)", "else if (look == 10)",
            "else if (look == 11)", "else if (look == 12)",
            "else if (look == 13)",
            "half4 creativeUniverse(",
            "kernel void storyCreativeUniverseFrame(",
            "universeEval(position,size,"
        ] {
            XCTAssertTrue(source.contains(signature), "Missing shader contract: \(signature)")
        }
        XCTAssertFalse(source.contains("look == 2 || look == 8"),
                       "Prism and Caustic must never be the same geometry")
    }

    func testArgonStage72BoundedGeometryAndExportShareIdenticalEvaluator() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf:
            root.appendingPathComponent("NightcoreLab/Resources/CreativeUniverse.metal"),
            encoding: .utf8)
        for signature in [
            "universePlateMetric(",
            "universeStrataHeight(",
            "if (q>0.60f)",
            "if (q>0.68f)",
            "float propulsion=t*0.92f+1.42f*bass+0.36f*voice;",
            "float aperture = 0.042f+0.102f*pressure;",
            "float terracing=17.0f+19.0f*age;",
            "return saturate(col);"
        ] {
            XCTAssertTrue(source.contains(signature), "Missing Stage 72 material: \\(signature)")
        }
        // Keep both entry points bound to ONE core: no duplicated live/export
        // geometry algorithms, no per-frame mutable simulation state.
        XCTAssertEqual(source.components(separatedBy: "universeEval(position,size,").count-1, 2)
        XCTAssertFalse(source.contains("threadgroup_barrier"),
                       "No persistent GPU texture state in this release")
        XCTAssertFalse(source.contains("t*(0.92f+1.42f*bass"),
                       "Bass must not multiply song elapsed time")
    }

    func testExistingVisualIdentityAndSavedIDsAreStable() {
        XCTAssertEqual(CreativeUniverseCatalog.lookID(
            theme: .xeroxSerpentine, materialID: "original-marble"), 1)
        XCTAssertEqual(CreativeUniverseCatalog.lookID(
            theme: .gnarlyStrata, materialID: "original-marble"), 13)
        XCTAssertEqual(CreativeUniverseCatalog.lookID(
            theme: .gnarlyCompiler, materialID: "original-marble"), 14)
        XCTAssertEqual(CreativeUniverseCatalog.lookID(
            theme: .gnarlyOrganism, materialID: "original-marble"), 15)
        for experience in CreativeUniverseCatalog.experiences {
            XCTAssertEqual(CreativeUniverseCatalog.lookID(
                theme: .acid, materialID: "gnarly-exp-" + experience.slug),
                experience.id)
        }
    }

    @MainActor
    func testRenderPipelineStillProducesActualPortraitPixelsForRemodeledLooks() throws {
        guard MTLCreateSystemDefaultDevice() != nil else {
            throw XCTSkip("Metal GPU not available on this runner")
        }
        let info = TrackInfo(
            track: Track(id: "12345678901", title: "Render contract",
                         thumbnailURL: nil), fileName: nil, coverURL: nil)
        for theme in [AppTheme.xeroxSerpentine, .gnarlyStrata] {
            let request = try StoryRequestBuilder.make(
                mode: .player, track: info, theme: theme,
                playerStyle: .turbulent, karaokeBackground: .marble,
                marblePhase: 7.3, playbackTime: 12,
                sourceDuration: 140, speed: 1,
                lines: [], lyricOffset: 0, typography: .neon,
                includeAudio: false, reactiveProgram: nil,
                reactiveSourceURL: nil)
            let frame = StoryRenderTimeline(
                request: request, profile: .economical).frame(at: 0.4)
            let image = try StoryFrameRenderer.render(
                request: request, artwork: nil, frame: frame,
                profile: .economical, visualTimeline: nil)
            XCTAssertGreaterThan(image.width, 0)
            XCTAssertGreaterThan(image.height, image.width)
            let data = try XCTUnwrap(image.dataProvider?.data as Data?)
            let bytes = [UInt8](data)
            XCTAssertGreaterThan(bytes.count, image.width * image.height)
            // Hashing the full image would be fragile across GPU drivers.
            // Sampling pixel luminances catches a shader that returns a flat
            // background after a failed Metal kernel/argument mapping.
            let step = max(4, bytes.count / 192)
            let samples = stride(from: 0, to: bytes.count, by: step)
                .map { bytes[$0] }
            XCTAssertGreaterThan(Set(samples).count, 5,
                                 "\(theme.rawValue) rendered as a flat surface")
        }
    }
}
