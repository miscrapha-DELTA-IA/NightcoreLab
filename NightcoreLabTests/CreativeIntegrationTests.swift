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

    /// Preview and export must receive EXACTLY the same resolved state: the
    /// preview's frame comes from `request.resolvedFrame` with the same audio
    /// timeline and rhythm the exporter uses, and both carry the same
    /// timestamp, AudioFeatures and RhythmFrame into the material.
    func testPreviewAndExportResolveIdenticalValues() throws {
        let source = rhythm()
        let envelope = audioTimeline()
        for reactive in [false, true] {
            for style in TypographyStyle.allCases {
                let story = try request(reactive: reactive, style: style)
                let runtime = try XCTUnwrap(story.compositionRuntime)
                let grid = StoryRenderTimeline(request: story, profile: .balanced)
                for index in stride(from: 0, to: grid.frameCount, by: 11) {
                    let frame = grid.frame(index: index)
                    // Exactly what StoryDraftPreview supplies.
                    let supplied = story.resolvedFrame(frame, audioTimeline: envelope,
                                                       rhythm: source)
                    let preview = StorySceneView(
                        request: story, artwork: nil, frame: grid.frame(at: frame.elapsed),
                        visualTimeline: envelope, visualRhythm: source,
                        resolvedCompositionFrame: supplied)
                    let export = StorySceneView(request: story, artwork: nil, frame: frame,
                                                visualTimeline: envelope, visualRhythm: source)
                    let context = "reactive=\(reactive) \(style) index=\(index)"
                    XCTAssertEqual(preview.resolvedCompositionFrame,
                                   export.resolvedCompositionFrame, context)
                    XCTAssertEqual(preview.materialFrame, export.materialFrame, context)
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
                    // The shared inputs, recomputed independently: same timestamp,
                    // same AudioFeatures, same RhythmFrame, same reaction gain.
                    let composed = try XCTUnwrap(export.resolvedCompositionFrame, context)
                    let sourceTime = composed.timestamp.sourceTime
                    let expected = MaterialResolver.resolve(
                        runtime.material,
                        features: CompositionAudioSampler.sample(envelope, at: sourceTime),
                        rhythm: RhythmFrame.at(sourceTime, in: source),
                        timestamp: sourceTime,
                        parameters: composed.programParameters,
                        reactionGain: CreativeReactionProfile.gain(
                            runtime.composition.program.preset.audioReaction))
                    XCTAssertEqual(export.materialFrame, expected, context)
                    XCTAssertEqual(export.materialFrame.timestamp, sourceTime, context)
                    if !reactive {
                        XCTAssertEqual(export.beatPulse, 0, context)
                        XCTAssertEqual(export.reactiveDistortion, 0, context)
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

    /// Experiences no longer imply the Marble: each one resolves, through the
    /// single material rule, to the material it authors; recipes to the
    /// reaction-free Marble of their program.
    func testExperiencesResolveTheirAuthoredMaterial() throws {
        let expected: [String: (id: String, type: VisualMaterialType)] = [
            "cyber-night": ("cyber-chrome", .marble),       // chrome-tuned Marble
            "liquid-dream": ("liquid-glass", .liquidGlass),
            "neon-pulse": ("neon-pulse", .marble),
            "chrome-night": ("chrome-night", .chrome),
            "organic-pulse": ("organic-pulse", .organicNoise),
            "cyber-marble": ("advanced-marble", .advancedMarble),
            "atmospheric-smoke": ("atmospheric-smoke", .atmosphericSmoke)
        ]
        for (experienceID, material) in expected {
            let preset = try XCTUnwrap(CreativePresetCatalog.selectedExperience(id: experienceID))
            let resolved = CreativePresetCatalog.material(selection: experienceID)
            XCTAssertEqual(resolved.id, material.id, experienceID)
            XCTAssertEqual(resolved.type, material.type, experienceID)
            XCTAssertEqual(resolved, preset.visualMaterial, experienceID)
            XCTAssertEqual(resolved, CreativeExperienceResolver.material(experience: preset))
            XCTAssertEqual(CreativeReactionProfile.materialRoute(for: resolved), .material,
                           "\(experienceID) maps audio in the material layer only")
        }
        for recipe in CreativePresetCatalog.all {
            let resolved = CreativePresetCatalog.material(selection: recipe.id)
            XCTAssertEqual(resolved, VisualMaterial.marble(for: recipe), recipe.id)
            XCTAssertEqual(resolved.type, .marble, recipe.id)
            XCTAssertEqual(CreativeReactionProfile.materialRoute(for: resolved), .program,
                           "\(recipe.id) keeps its program equations")
        }
        XCTAssertEqual(CreativePresetCatalog.material(selection: "unknown"),
                       VisualMaterial.marble(for: CreativePresetCatalog.program(for: "original")))
        // Every experience material resolves deterministically.
        for preset in CreativePresetCatalog.experiencePresets {
            let frame = RhythmFrame.at(1.0, in: rhythm())
            XCTAssertEqual(MaterialResolver.resolve(preset.visualMaterial, rhythm: frame, timestamp: 1),
                           MaterialResolver.resolve(preset.visualMaterial, rhythm: frame, timestamp: 1),
                           preset.id)
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
        let curated = CreativePresetCatalog.experiencePresets.map { $0.id }
        for id in ["cyber-night", "liquid-dream", "neon-pulse"] {
            XCTAssertTrue(curated.contains(id), id)
        }
        XCTAssertEqual(Set(curated).count, curated.count)
    }

    // MARK: Helpers

    /// Beats every 0.5 s and a moving envelope over 0…30 s.
    private func audioTimeline() -> AudioFeatureTimeline {
        var points: [AudioFeaturePoint] = []
        for index in 0..<300 {
            let time: Double = Double(index) * 0.1
            let wave: Double = 0.5 + 0.5 * sin(Double(index) * 0.37)
            let features = AudioFeatures(bass: wave, mid: 0.4, treble: 1 - wave,
                                         energy: 0.3 + 0.6 * wave,
                                         beatDetected: index % 5 == 0)
            points.append(AudioFeaturePoint(time: time, features: features))
        }
        return AudioFeatureTimeline(points: points, duration: 30)
    }

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
