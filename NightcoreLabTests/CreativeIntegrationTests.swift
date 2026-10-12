import Foundation
import UIKit
import XCTest
@testable import NightcoreLab

/// Integration of Stages 10A (layer pixels), 10B (typography), 10C (runtime),
/// 11 (rhythm) and 12 (material): one frozen request, one runtime, the same
/// values in Story preview and MP4.
final class CreativeIntegrationTests: XCTestCase {
    private func track() -> TrackInfo {
        TrackInfo(track: Track(id: "12345678901", title: "Integration",
                               thumbnailURL: nil, cleanArtist: "Nightcore"),
                  fileName: nil, coverURL: nil)
    }

    private func line() -> TimedLyricLine {
        TimedLyricLine(id: 0, start: 1, end: 9, words: [
            WordSync(id: 0, text: "ONE", start: 1, end: 3, spaceAfter: true),
            WordSync(id: 1, text: "ENGINE", start: 3, end: 9, spaceAfter: false)
        ], precision: .word)
    }

    private func request(mode: StoryMode = .lyrics, reactive: Bool,
                         background: NightcoreLab.BackgroundStyle = .marble,
                         style: TypographyStyle = .neon) throws -> StoryVideoRequest {
        try StoryRequestBuilder.make(
            mode: mode, track: track(), theme: .cyber,
            playerStyle: .turbulent, karaokeBackground: background,
            marblePhase: 2, playbackTime: 0.5, sourceDuration: 30,
            speed: 1.2, lines: [line()], lyricOffset: 0.05,
            typography: .classic, typographyStyle: style, includeAudio: false,
            reactiveProgram: reactive ? CreativePresetCatalog.effectiveProgram(
                id: "night-drive", theme: .cyber, typography: style,
                background: .turbulent, reaction: .responsive) : nil,
            reactiveSourceURL: nil,
            creativePresetID: "night-drive")
    }

    // MARK: Always one runtime

    func testEveryBuiltRequestFreezesOneRuntime() throws {
        let off = try request(reactive: false)
        let runtime = try XCTUnwrap(off.compositionRuntime)
        XCTAssertEqual(runtime.composition.program.preset.audioReaction, .off)
        XCTAssertEqual(runtime.composition.program.id, "night-drive",
                       "The selected recipe is frozen even with reaction off")
        XCTAssertNil(off.reactiveProgram)

        let on = try request(reactive: true)
        XCTAssertEqual(on.compositionRuntime?.composition.program.preset.audioReaction,
                       .responsive)
    }

    // MARK: Preview = export, field by field

    func testPreviewAndExportResolveIdenticalValues() throws {
        let source = rhythm()
        for reactive in [false, true] {
            for style in TypographyStyle.allCases {
                let story = try request(reactive: reactive, style: style)
                let grid = StoryRenderTimeline(request: story, profile: .balanced)
                for index in stride(from: 0, to: grid.frameCount, by: 11) {
                    let frame = grid.frame(index: index)
                    let layer = TypographyLayer.forStory(
                        lines: story.lines, lyricTime: frame.lyricTime,
                        lyricOffset: story.lyricOffset, preset: story.typographyPreset,
                        prepared: story.preparedLyrics)
                    let supplied = story.compositionRuntime?.frame(
                        at: frame.elapsed, audioTimeline: nil, typography: layer)
                    let preview = StorySceneView(
                        request: story, artwork: nil, frame: grid.frame(at: frame.elapsed),
                        visualRhythm: source, resolvedCompositionFrame: supplied)
                    let export = StorySceneView(request: story, artwork: nil, frame: frame,
                                                visualRhythm: source)
                    let context = "reactive=\(reactive) \(style) index=\(index)"
                    XCTAssertEqual(preview.resolvedCompositionFrame,
                                   export.resolvedCompositionFrame, context)
                    XCTAssertEqual(preview.typographyFrame, export.typographyFrame, context)
                    XCTAssertEqual(preview.reactiveDistortion, export.reactiveDistortion, context)
                    XCTAssertEqual(preview.beatPulse, export.beatPulse, context)
                    for kind in PresetLayerKind.allCases {
                        XCTAssertEqual(
                            ResolvedLayerFrame.storyModifiers(
                                kind: kind, frame: preview.resolvedCompositionFrame),
                            ResolvedLayerFrame.storyModifiers(
                                kind: kind, frame: export.resolvedCompositionFrame),
                            context)
                    }
                }
            }
        }
    }

    // MARK: Layer pixels (Stage 10A)

    func testDefaultLayersAreAnExactBypass() throws {
        let story = try request(reactive: true)
        let frame = StoryRenderTimeline(request: story, profile: .balanced).frame(index: 30)
        let scene = StorySceneView(request: story, artwork: nil, frame: frame)
        for kind in PresetLayerKind.allCases {
            XCTAssertTrue(ResolvedLayerFrame.storyModifiers(
                kind: kind, frame: scene.resolvedCompositionFrame).isIdentity, "\(kind)")
        }
        XCTAssertTrue(ResolvedLayerFrame.storyModifiers(kind: .overlay, frame: nil).isIdentity)
    }

    func testLayerValuesMapToStoryCanvasUnits() throws {
        let story = try request(reactive: true)
        var custom = story
        let base = try XCTUnwrap(story.visualComposition)
        let layers = base.layers.map { layer -> PresetLayer in
            guard layer.kind == .artwork else { return layer }
            return PresetLayer(id: layer.id, kind: layer.kind, zIndex: layer.zIndex,
                               properties: [.opacity: 0.5, .scale: 0.8,
                                            .offsetX: 0.1, .offsetY: -0.05,
                                            .rotation: 0.2])
        }
        custom.visualComposition = try VisualComposition(
            id: base.id, name: base.name, program: base.program, layers: layers,
            timeline: base.timeline, deterministicSeed: base.deterministicSeed)
        let frame = StoryRenderTimeline(request: custom, profile: .balanced).frame(index: 5)
        let scene = StorySceneView(request: custom, artwork: nil, frame: frame)
        let artwork = ResolvedLayerFrame.storyModifiers(
            kind: .artwork, frame: scene.resolvedCompositionFrame)
        XCTAssertEqual(artwork, StoryLayerModifiers(opacity: 0.5, scale: 0.8,
                                                    offsetX: 54, offsetY: -48, rotation: 0.2))
        // A clip that excludes the frame hides the element.
        let hidden = base.layers.map { layer -> PresetLayer in
            guard layer.kind == .overlay else { return layer }
            return PresetLayer(id: layer.id, kind: layer.kind, zIndex: layer.zIndex,
                               activeRange: CompositionClip(start: 10, end: 12))
        }
        custom.visualComposition = try VisualComposition(
            id: base.id, name: base.name, program: base.program, layers: hidden,
            timeline: base.timeline, deterministicSeed: base.deterministicSeed)
        let clipped = StorySceneView(request: custom, artwork: nil, frame: frame)
        XCTAssertEqual(ResolvedLayerFrame.storyModifiers(
            kind: .overlay, frame: clipped.resolvedCompositionFrame).opacity, 0)
    }

    @MainActor
    func testLayerValuesReachTheExportedPixels() throws {
        // Cover background with a flat artwork: no Metal noise in the frame.
        let artwork = UIGraphicsImageRenderer(size: CGSize(width: 16, height: 16))
            .image { context in
                UIColor(red: 0.8, green: 0.2, blue: 0.4, alpha: 1).setFill()
                context.fill(CGRect(x: 0, y: 0, width: 16, height: 16))
            }
        let story = try request(reactive: false, background: .cover)
        var dimmed = story
        let base = try XCTUnwrap(story.visualComposition)
        dimmed.visualComposition = try VisualComposition(
            id: base.id, name: base.name, program: base.program,
            layers: base.layers.map { layer in
                layer.kind == .overlay ? PresetLayer(
                    id: layer.id, kind: layer.kind, zIndex: layer.zIndex,
                    properties: [.opacity: 0]) : layer
            },
            timeline: base.timeline, deterministicSeed: base.deterministicSeed)
        let profile = StoryEncodingProfile.economical
        let frame = StoryRenderTimeline(request: story, profile: profile).frame(index: 10)
        let normal = try pixels(StoryFrameRenderer.render(
            request: story, artwork: artwork, frame: frame, profile: profile))
        let withoutScrim = try pixels(StoryFrameRenderer.render(
            request: dimmed, artwork: artwork, frame: frame, profile: profile))
        XCTAssertNotEqual(normal, withoutScrim, "Overlay opacity must change exported pixels")
    }

    // MARK: Experience → material → uniforms (Stage 12)

    func testExperiencePresetsDriveTheMarbleMaterial() throws {
        for preset in CreativePresetCatalog.experiencePresets {
            let material = preset.visualMaterial
            XCTAssertEqual(material, VisualMaterial.marble(for: preset.composition.program))
            XCTAssertEqual(material.kind, .marble)
            let uniforms = MaterialResolver.marble(
                material, parameters: .neutral,
                rhythm: RhythmFrame.at(1.0, in: rhythm()))
            XCTAssertTrue((0...1).contains(uniforms.beatPulse), preset.id)
            XCTAssertEqual(uniforms.distortion, 0, preset.id)
            // Deterministic.
            XCTAssertEqual(uniforms, MaterialResolver.marble(
                material, parameters: .neutral,
                rhythm: RhythmFrame.at(1.0, in: rhythm())))
        }
    }

    // MARK: Preset compatibility

    func testBuiltInAndExperiencePresetsRoundTrip() throws {
        for program in CreativePresetCatalog.all {
            let package = try XCTUnwrap(CreativePresetCatalog.builtInPackage(for: program.id))
            XCTAssertEqual(try JSONDecoder().decode(
                CreativePresetPackage.self, from: JSONEncoder().encode(package)), package)
        }
        for experience in CreativePresetCatalog.experiencePresets {
            XCTAssertEqual(try JSONDecoder().decode(
                CreativeExperiencePreset.self, from: JSONEncoder().encode(experience)),
                experience)
        }
        XCTAssertEqual(CreativePresetCatalog.experiencePresets.count, 7)
    }

    // MARK: Helpers

    private func rhythm() -> RhythmAnalysisResult {
        let grid: [RhythmAnalysisResult.BeatEvent] = (0..<40).map { (index: Int) in
            let time: Double = 0.5 + 0.48 * Double(index)
            return RhythmAnalysisResult.BeatEvent(time: time, index: index,
                                                  strength: 1, isDownbeat: index % 4 == 0)
        }
        return RhythmAnalysisResult(onsetEvents: grid.map { $0.time },
                                    bpmCandidates: [.init(bpm: 125, confidence: 0.9)],
                                    beatGrid: grid, confidence: 0.9,
                                    downbeatConfidence: 0.8)
    }

    private func pixels(_ image: CGImage) -> [UInt8] {
        var data = [UInt8](repeating: 0, count: image.width * image.height * 4)
        data.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(
                data: buffer.baseAddress, width: image.width, height: image.height,
                bitsPerComponent: 8, bytesPerRow: image.width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        return data
    }
}
