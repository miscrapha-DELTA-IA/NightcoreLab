import Foundation
import UIKit
import XCTest
@testable import NightcoreLab

/// Stage 12.5 — Creative Experience UX integration.
///
/// One selection key (`creativePresetID`) for recipes and complete
/// experiences. Selecting Cyber Night / Liquid Dream / Neon Pulse loads the
/// experience's program (visual), typography preset, audio mapping and
/// composition; the live karaoke, the Story preview and the MP4 then resolve
/// the same values for the same source time.
final class CreativeExperienceUXTests: XCTestCase {
    private let experienceIDs = ["cyber-night", "liquid-dream", "neon-pulse"]

    private func track() -> TrackInfo {
        TrackInfo(track: Track(id: "12345678901", title: "Experience",
                               thumbnailURL: nil, cleanArtist: "Nightcore"),
                  fileName: nil, coverURL: nil)
    }

    private func line() -> TimedLyricLine {
        TimedLyricLine(id: 0, start: 0.5, end: 19, words: [
            WordSync(id: 0, text: "NEON", start: 0.5, end: 4, spaceAfter: true),
            WordSync(id: 1, text: "NIGHT", start: 4, end: 9, spaceAfter: true),
            WordSync(id: 2, text: "DRIVE", start: 9, end: 19, spaceAfter: false)
        ], precision: .word)
    }

    /// Beats every 0.5 s and a moving bass/energy envelope, 0…30 s.
    private func timeline() -> AudioFeatureTimeline {
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

    private func experience(_ id: String) throws -> CreativeExperiencePreset {
        try XCTUnwrap(CreativePresetCatalog.selectedExperience(id: id), id)
    }

    /// Exactly what NowPlayingScreen.shareVideo passes for a selection.
    private func request(selection id: String, style: TypographyStyle,
                         reactive: Bool) throws -> StoryVideoRequest {
        try StoryRequestBuilder.make(
            mode: .lyrics, track: track(), theme: .acid,
            playerStyle: .turbulent, karaokeBackground: .marble,
            marblePhase: 1, playbackTime: 0.5, sourceDuration: 30,
            speed: 1.2, lines: [line()], lyricOffset: 0.05,
            typography: .mono, typographyStyle: style, includeAudio: false,
            reactiveProgram: reactive ? CreativePresetCatalog.effectiveProgram(
                id: id, theme: .acid, typography: style,
                background: .turbulent, reaction: .responsive) : nil,
            reactiveSourceURL: nil,
            creativePresetID: id)
    }

    // MARK: Phase 1 — selection

    func testExperiencesShareTheExistingPresetSelection() throws {
        let selectable: [String] = CreativePresetCatalog.selectableExperiences.map { $0.id }
        XCTAssertEqual(Array(selectable.prefix(experienceIDs.count)), experienceIDs)
        XCTAssertEqual(Set(selectable).count, selectable.count)
        XCTAssertEqual(selectable, CreativePresetCatalog.experiencePresets.map { $0.id },
                       "Every curated experience is offered, once")
        let recipeIDs: Set<String> = Set(CreativePresetCatalog.all.map { $0.id })
        for id in experienceIDs {
            XCTAssertFalse(recipeIDs.contains(id), "\(id) must not shadow a recipe")
            XCTAssertEqual(CreativePresetCatalog.recipe(for: id),
                           try experience(id).composition.program, id)
        }
        // Recipes and unknown ids keep their pre-12.5 resolution.
        for program in CreativePresetCatalog.all {
            XCTAssertNil(CreativePresetCatalog.selectedExperience(id: program.id))
            XCTAssertEqual(CreativePresetCatalog.recipe(for: program.id), program)
        }
        XCTAssertEqual(CreativePresetCatalog.recipe(for: "unknown").id, "original")
        XCTAssertEqual(CreativePresetCatalog.program(for: "cyber-night").id, "original",
                       "program(for:) is unchanged; experiences resolve through recipe(for:)")
    }

    func testSelectingAnExperienceLoadsVisualTypographyMappingAndComposition() throws {
        for id in experienceIDs {
            let authored = try experience(id)
            let source = authored.composition.program
            // Visual: the experience's program reaches the effective program.
            let effective = CreativePresetCatalog.effectiveProgram(
                id: id, theme: .acid, typography: authored.typographyPreset.style,
                background: .turbulent, reaction: .responsive)
            XCTAssertEqual(effective.id, id)
            XCTAssertEqual(effective.rules, source.rules, id)
            XCTAssertEqual(effective.preset.visualStyle.shaderParameters,
                           source.preset.visualStyle.shaderParameters, id)
            XCTAssertEqual(effective.preset.visualStyle.intensity,
                           source.preset.visualStyle.intensity, id)
            XCTAssertEqual(effective.preset.visualStyle.motion,
                           source.preset.visualStyle.motion, id)
            XCTAssertEqual(effective.preset.theme, .acid, "the AppTheme is never replaced")
            // Material: same Marble material as the experience declares.
            XCTAssertEqual(CreativePresetCatalog.selectedExperience(id: id)?.material,
                           authored.visualMaterial, id)

            // Typography: the style becomes the karaoke preference ...
            let style = CreativePresetCatalog.typographyStyle(afterSelecting: id, current: .neon)
            XCTAssertEqual(style, authored.typographyPreset.style, id)
            // ... and its authored intensity / seed / mapping apply, with the user's font.
            let preset = CreativePresetCatalog.typographyPreset(
                selection: id, style: style, font: .mono, reacts: true)
            XCTAssertEqual(preset.effectIntensity, authored.typographyPreset.effectIntensity, id)
            XCTAssertEqual(preset.deterministicSeed, authored.typographyPreset.deterministicSeed, id)
            XCTAssertEqual(preset.audioMapping, authored.typographyPreset.audioMapping, id)
            XCTAssertEqual(preset.audioReaction, authored.typographyPreset.audioReaction, id)
            XCTAssertEqual(preset.font, .mono)
            // Audio mapping only while the visuals react.
            XCTAssertEqual(CreativePresetCatalog.typographyAudioMapping(
                selection: id, style: style, reacts: true), authored.audioMapping, id)
            XCTAssertEqual(CreativePresetCatalog.typographyAudioMapping(
                selection: id, style: style, reacts: false), .disabled, id)
            XCTAssertEqual(CreativePresetCatalog.typographyPreset(
                selection: id, style: style, font: .mono, reacts: false).audioReaction, .off, id)
        }
    }

    func testRecipesAndOverriddenStylesKeepThePreviousTypography() throws {
        // A recipe never changes the karaoke style.
        XCTAssertEqual(CreativePresetCatalog.typographyStyle(
            afterSelecting: "bass-pulse", current: .minimal), .minimal)
        for style in TypographyStyle.allCases {
            for font in TypographyFont.allCases {
                XCTAssertEqual(CreativePresetCatalog.typographyPreset(
                    selection: "night-drive", style: style, font: font, reacts: true),
                    .current(style: style, font: font))
            }
        }
        // The user may pick another style after an experience: plain preset.
        XCTAssertEqual(CreativePresetCatalog.typographyPreset(
            selection: "cyber-night", style: .neon, font: .classic, reacts: true),
            .current(style: .neon, font: .classic))
        XCTAssertEqual(CreativePresetCatalog.typographyAudioMapping(
            selection: "cyber-night", style: .neon, reacts: true), .disabled)
    }

    // MARK: Phase 2 — preview parity

    func testStoryFreezesTheSelectedExperience() throws {
        for id in experienceIDs {
            let authored = try experience(id)
            let style = authored.typographyPreset.style
            let story = try request(selection: id, style: style, reactive: true)
            let composition = try XCTUnwrap(story.visualComposition, id)
            XCTAssertEqual(composition.program.id, id)
            XCTAssertEqual(composition.program.rules, authored.composition.program.rules, id)
            XCTAssertEqual(composition.deterministicSeed,
                           authored.composition.deterministicSeed, id)
            XCTAssertEqual(story.typographyPreset, CreativePresetCatalog.typographyPreset(
                selection: id, style: style, font: .mono, reacts: true), id)
            XCTAssertEqual(story.typographyAudioMapping, authored.audioMapping, id)
            XCTAssertEqual(story.compositionRuntime?.material,
                           authored.visualMaterial, id)

            let quiet = try request(selection: id, style: style, reactive: false)
            XCTAssertEqual(quiet.visualComposition?.program.id, id)
            XCTAssertEqual(quiet.typographyAudioMapping, .disabled, id)
            XCTAssertEqual(quiet.typographyPreset.audioReaction, .off, id)
            XCTAssertEqual(quiet.typographyPreset.effectIntensity,
                           authored.typographyPreset.effectIntensity, id)
        }
    }

    func testExperiencePreviewAndExportResolveIdenticalFrames() throws {
        let envelope = timeline()
        for id in experienceIDs {
            let style = try experience(id).typographyPreset.style
            let story = try request(selection: id, style: style, reactive: true)
            let grid = StoryRenderTimeline(request: story, profile: .balanced)
            let runtime = try XCTUnwrap(story.compositionRuntime)
            for index in stride(from: 0, to: grid.frameCount, by: 9) {
                let frame = grid.frame(index: index)
                // Exactly what StoryDraftPreview supplies.
                let supplied = runtime.frame(
                    at: frame.elapsed, audioTimeline: envelope,
                    typography: story.typographyLayer(atLyricTime: frame.lyricTime))
                let preview = StorySceneView(
                    request: story, artwork: nil, frame: grid.frame(at: frame.elapsed),
                    visualTimeline: envelope, resolvedCompositionFrame: supplied)
                let export = StorySceneView(request: story, artwork: nil, frame: frame,
                                            visualTimeline: envelope)
                let context = "\(id) index=\(index)"
                XCTAssertNotNil(export.typographyFrame, context)
                XCTAssertEqual(preview.resolvedCompositionFrame,
                               export.resolvedCompositionFrame, context)
                XCTAssertEqual(preview.typographyFrame, export.typographyFrame, context)
                XCTAssertEqual(preview.reactiveDistortion, export.reactiveDistortion, context)
                XCTAssertEqual(preview.beatPulse, export.beatPulse, context)
            }
        }
    }

    /// The experience's audio mapping must really reach the exported frames.
    func testExperienceMappingReachesStoryTypography() throws {
        let envelope = timeline()
        let story = try request(selection: "cyber-night", style: .glitch, reactive: true)
        let grid = StoryRenderTimeline(request: story, profile: .balanced)
        var intensities = Set<Double>()
        for index in 0..<grid.frameCount {
            let frame = grid.frame(index: index)
            let scene = StorySceneView(request: story, artwork: nil, frame: frame,
                                       visualTimeline: envelope)
            if let preset = scene.typographyFrame?.preset { intensities.insert(preset.effectIntensity) }
        }
        let authored = try experience("cyber-night").typographyPreset.effectIntensity
        XCTAssertTrue(intensities.contains(authored), "frames without a beat keep the authored value")
        XCTAssertTrue(intensities.contains(where: { (value: Double) -> Bool in value > authored }),
                      "beats raise the effect intensity")
        XCTAssertTrue(intensities.allSatisfy { (value: Double) -> Bool in value <= 1 })
    }

    /// The live karaoke path (KaraokeLineView) and the Story agree for the
    /// same source time: same preset, same envelope, same feature sampler.
    @MainActor
    func testLiveKaraokeTypographyMatchesTheStory() throws {
        let envelope = timeline()
        let live = CreativeLiveUniforms()
        live.setFeatureTimeline(envelope)
        for id in experienceIDs {
            let style = try experience(id).typographyPreset.style
            let story = try request(selection: id, style: style, reactive: true)
            let composition = try XCTUnwrap(story.visualComposition)
            let grid = StoryRenderTimeline(request: story, profile: .balanced)
            // KaraokeLyricsView's inputs for the same selection with reaction on.
            let preset = CreativePresetCatalog.typographyPreset(
                selection: id, style: style, font: .mono, reacts: true)
            let mapping = CreativePresetCatalog.typographyAudioMapping(
                selection: id, style: style, reacts: true)
            for index in stride(from: 3, to: grid.frameCount, by: 13) {
                let frame = grid.frame(index: index)
                let export = StorySceneView(request: story, artwork: nil, frame: frame,
                                            visualTimeline: envelope)
                // The player clock's source time for this Story frame.
                let source = try XCTUnwrap(composition.timeline.timestamp(at: frame.elapsed)).sourceTime
                let karaoke = TypographyLayer(
                    state: LyricsState(line: line(), status: .active), preset: preset,
                    lyricOffset: story.lyricOffset,
                    prepared: TypographyPreparedLine(line()),
                    experienceMapping: mapping)
                    .resolve(at: source + story.lyricOffset,
                             features: live.typographyFeatures(at: source))
                XCTAssertEqual(karaoke, export.typographyFrame, "\(id) index=\(index)")
            }
        }
        live.setFeatureTimeline(nil)
        XCTAssertNil(live.typographyFeatures(at: 2))
    }

    @MainActor
    func testExportedPixelsFollowTheSelectedExperience() throws {
        let artwork = UIGraphicsImageRenderer(size: CGSize(width: 32, height: 32))
            .image { context in
                UIColor(red: 0.1, green: 0.1, blue: 0.3, alpha: 1).setFill()
                context.fill(CGRect(x: 0, y: 0, width: 32, height: 32))
            }
        func pixels(_ id: String, _ style: TypographyStyle) throws -> Data? {
            let story = try StoryRequestBuilder.make(
                mode: .lyrics, track: track(), theme: .acid,
                playerStyle: .turbulent, karaokeBackground: .cover,
                marblePhase: 1, playbackTime: 0.5, sourceDuration: 30,
                speed: 1, lines: [line()], lyricOffset: 0,
                typography: .classic, typographyStyle: style, includeAudio: false,
                creativePresetID: id)
            let profile = StoryEncodingProfile.economical
            let frame = StoryRenderTimeline(request: story, profile: profile).frame(index: 20)
            let image = try StoryFrameRenderer.render(
                request: story, artwork: artwork, frame: frame, profile: profile)
            return UIImage(cgImage: image).pngData()
        }
        // Liquid Dream selects Magazine Cutout: a different export than Neon.
        XCTAssertNotEqual(try pixels("liquid-dream", .magazineCutout),
                          try pixels("original", .neon))
    }
}
