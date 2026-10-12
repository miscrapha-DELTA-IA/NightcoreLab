import CoreGraphics
import Foundation
import SwiftUI
import UIKit
import XCTest
@testable import NightcoreLab

final class StoryPixelConsumptionTests: XCTestCase {
    private let profile = StoryEncodingProfile.economical

    private func lines() -> [TimedLyricLine] {
        [TimedLyricLine(id: 17, start: 2, end: 6, words: [
            WordSync(id: 0, text: "NEON", start: 2, end: 4, spaceAfter: true),
            WordSync(id: 1, text: "MUSIC", start: 4, end: 6, spaceAfter: false)
        ], precision: .word)]
    }

    private func request(_ mode: StoryMode,
                         karaoke: KaraokeTypographyStyle = .neon) throws -> StoryVideoRequest {
        let track = TrackInfo(
            track: Track(id: "12345678901", title: "Proof of Pixels",
                         thumbnailURL: nil, cleanArtist: "Stage 10A"),
            fileName: nil, coverURL: nil)
        return try StoryRequestBuilder.make(
            mode: mode, track: track, theme: .acid, playerStyle: .turbulent,
            karaokeBackground: .marble, marblePhase: 1.8,
            playbackTime: 2, sourceDuration: 12, speed: 1,
            lines: lines(), lyricOffset: 0, typography: .classic,
            includeAudio: false, karaokeTypography: karaoke)
    }

    private func amended(_ base: StoryVideoRequest,
                         kind: PresetLayerKind, property: LayerProperty,
                         value: Double, clipped: CompositionClip? = nil)
        throws -> StoryVideoRequest {
        let composition = try XCTUnwrap(base.visualComposition)
        let changedLayers = composition.layers.map { layer -> PresetLayer in
            guard layer.kind == kind else { return layer }
            return PresetLayer(
                id: layer.id, kind: layer.kind, zIndex: layer.zIndex,
                activeRange: clipped ?? layer.activeRange,
                properties: [property: value],
                bindings: layer.bindings, keyframes: layer.keyframes)
        }
        let changed = try VisualComposition(
            id: composition.id, name: composition.name,
            program: composition.program, layers: changedLayers,
            timeline: composition.timeline,
            deterministicSeed: composition.deterministicSeed)
        var request = base
        request.compositionRuntime = CompositionRuntime(
            composition: changed, lyrics: base.lines)
        return request
    }

    /// Explicitly convert both CGImages to the same RGBA layout before
    /// comparing bytes; comparison includes every pixel, not metadata.
    private func pixels(_ image: CGImage) throws -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let didDraw: Bool = bytes.withUnsafeMutableBytes { buffer in
            guard let ctx = CGContext(
                data: buffer.baseAddress, width: image.width,
                height: image.height, bitsPerComponent: 8,
                bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return false }
            ctx.draw(image, in: CGRect(x: 0, y: 0,
                                      width: image.width, height: image.height))
            return true
        }
        XCTAssertTrue(didDraw)
        return bytes
    }

    @MainActor
    private func previewPixels(_ request: StoryVideoRequest,
                               at frame: StoryRenderFrame) throws -> [UInt8] {
        let supplied = StoryDraftPreview.resolveFrame(
            request: request, frame: frame, visualTimeline: nil)
        let scene = StorySceneView(
            request: request, artwork: nil, frame: frame,
            resolvedCompositionFrame: supplied)
        let renderer = ImageRenderer(content: scene)
        renderer.proposedSize = ProposedViewSize(StoryVideoRequest.size)
        renderer.scale = profile.scale
        return try pixels(XCTUnwrap(renderer.uiImage?.cgImage))
    }

    @MainActor
    private func exportPixels(_ request: StoryVideoRequest,
                              at frame: StoryRenderFrame) throws -> [UInt8] {
        try pixels(StoryFrameRenderer.render(
            request: request, artwork: nil, frame: frame, profile: profile))
    }

    private func frame(_ request: StoryVideoRequest,
                       index: Int = 20) -> StoryRenderFrame {
        StoryRenderTimeline(request: request, profile: profile).frame(index: index)
    }

    @MainActor
    func testNeutralCompositionIsPixelIdenticalToLegacyForBothStoryModes() throws {
        for mode in [StoryMode.player, .lyrics] {
            let compiled = try request(mode)
            XCTAssertNotNil(compiled.compositionRuntime)
            XCTAssertEqual(compiled.compositionRuntime?.composition.layers,
                           PresetLayer.defaultLayers)
            XCTAssertEqual(compiled.compositionRuntime?.composition
                           .program.preset.audioReaction, .off)
            var legacy = compiled
            legacy.compositionRuntime = nil
            let f = frame(compiled)
            XCTAssertNil(StoryDraftPreview.resolveFrame(
                request: legacy, frame: f, visualTimeline: nil))
            XCTAssertEqual(try exportPixels(legacy, at: f),
                           try exportPixels(compiled, at: f),
                           "Default composition must preserve \(mode) pixels")
            XCTAssertEqual(try previewPixels(compiled, at: f),
                           try exportPixels(compiled, at: f))
        }
    }

    @MainActor
    func testOverlayOpacityZeroChangesPixelsInPreviewAndMP4() throws {
        let baseline = try request(.player)
        let changed = try amended(baseline, kind: .overlay,
                                  property: .opacity, value: 0)
        let f = frame(changed)
        let original = try exportPixels(baseline, at: f)
        let mp4Raster = try exportPixels(changed, at: f)
        XCTAssertNotEqual(original, mp4Raster,
                          "The scrim layer must visibly disappear")
        XCTAssertEqual(try previewPixels(changed, at: f), mp4Raster)
    }

    @MainActor
    func testArtworkScaleHalfChangesPixelsInPreviewAndMP4() throws {
        let baseline = try request(.player)
        let changed = try amended(baseline, kind: .artwork,
                                  property: .scale, value: 0.5)
        let f = frame(changed)
        let original = try exportPixels(baseline, at: f)
        let mp4Raster = try exportPixels(changed, at: f)
        XCTAssertNotEqual(original, mp4Raster,
                          "The artwork tile must scale visibly")
        XCTAssertEqual(try previewPixels(changed, at: f), mp4Raster)
    }

    @MainActor
    func testMagazineChangesPixelsAndPreviewEqualsExport() throws {
        let neon = try request(.lyrics, karaoke: .neon)
        let magazine = try request(.lyrics, karaoke: .magazineCutout)
        let f = frame(magazine)
        let resolved = try XCTUnwrap(StoryDraftPreview.resolveFrame(
            request: magazine, frame: f, visualTimeline: nil))
        let typography = try XCTUnwrap(resolved.typographyFrame)
        XCTAssertEqual(typography.preset.style, .magazineCutout)
        XCTAssertTrue(typography.animations.values.contains {
            !$0.isTransformNeutral
        })
        XCTAssertNotEqual(try exportPixels(neon, at: f),
                          try exportPixels(magazine, at: f))
        XCTAssertEqual(try previewPixels(magazine, at: f),
                       try exportPixels(magazine, at: f))
    }

    @MainActor
    func testNeonZeroIntensityMatchesLegacyBytes() throws {
        let standard = try request(.lyrics, karaoke: .neon)
        var legacy = standard
        legacy.compositionRuntime = nil
        let f = frame(standard)
        let resolved = try XCTUnwrap(StoryDraftPreview.resolveFrame(
            request: standard, frame: f, visualTimeline: nil))
        let typography = try XCTUnwrap(resolved.typographyFrame)
        XCTAssertEqual(typography.preset.effectIntensity, 0)
        XCTAssertTrue(typography.animations.values.allSatisfy {
            $0.isTransformNeutral
        })
        XCTAssertEqual(try exportPixels(standard, at: f),
                       try exportPixels(legacy, at: f))
    }

    @MainActor
    func testInactiveTypographyLayerChangesPixelsInBothPaths() throws {
        let base = try request(.lyrics)
        let modified = try amended(base, kind: .typography,
                                   property: .opacity, value: 1,
                                   clipped: CompositionClip(start: 2, end: 8))
        let f = frame(modified, index: 20) // 1s; layer outside clip
        let resolved = try XCTUnwrap(StoryDraftPreview.resolveFrame(
            request: modified, frame: f, visualTimeline: nil))
        XCTAssertNil(resolved.typographyFrame)
        XCTAssertEqual(ResolvedLayerFrame.storyModifiers(
            kind: .typography, frame: resolved).opacity, 0)
        XCTAssertNotEqual(try exportPixels(base, at: f),
                          try exportPixels(modified, at: f))
        XCTAssertEqual(try previewPixels(modified, at: f),
                       try exportPixels(modified, at: f))
    }
}
