import Foundation
import SwiftUI
import UIKit
import XCTest
@testable import NightcoreLab

/// Stage 10B: the typography the user picks in the app is the typography
/// resolved and drawn in the Story preview and the MP4.
final class TypographyExportParityTests: XCTestCase {
    private let fonts: [TypographyFont] = [.classic, .cinematic]

    private func line() -> TimedLyricLine {
        TimedLyricLine(id: 3, start: 2, end: 6, words: [
            WordSync(id: 0, text: "NEON", start: 2, end: 3.2, spaceAfter: true),
            WordSync(id: 1, text: "NIGHT", start: 3.2, end: 4.6, spaceAfter: true),
            WordSync(id: 2, text: "DRIVE", start: 4.6, end: 6, spaceAfter: false)
        ], precision: .word)
    }

    private func track() -> TrackInfo {
        TrackInfo(track: Track(id: "12345678901", title: "Parity",
                               thumbnailURL: nil, cleanArtist: "Nightcore"),
                  fileName: nil, coverURL: nil)
    }

    private func request(style: TypographyStyle, font: TypographyFont,
                         reactive: Bool = false,
                         background: BackgroundStyle = .marble) throws -> StoryVideoRequest {
        let program = reactive ? CreativePresetCatalog.effectiveProgram(
            id: "bass-pulse", theme: .acid, typography: style,
            background: .turbulent, reaction: .responsive) : nil
        return try StoryRequestBuilder.make(
            mode: .lyrics, track: track(), theme: .acid,
            playerStyle: .turbulent, karaokeBackground: background,
            marblePhase: 1, playbackTime: 1.5, sourceDuration: 10,
            speed: 1, lines: [line()], lyricOffset: 0,
            typography: font, typographyStyle: style, includeAudio: false,
            reactiveProgram: program, reactiveSourceURL: nil)
    }

    /// Exactly what KaraokeLineView resolves for the active line.
    private func appFrame(style: TypographyStyle, font: TypographyFont,
                          at lyricTime: TimeInterval) -> TypographyFrame {
        TypographyResolver.resolve(
            LyricsState(line: line(), status: .active), at: lyricTime,
            features: nil, preset: .current(style: style, font: font),
            prepared: TypographyPreparedLine(line()))
    }

    // MARK: Compatibility

    func testPersistedSelectionsKeepDecoding() throws {
        let suite = "nightcore.parity.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        // Values written by the pre-10B KaraokeTypographyStyle/StoryLyricTypography.
        defaults.set("magazineCutout", forKey: TypographyStyle.storageKey)
        defaults.set("cinematic", forKey: TypographyFont.storageKey)
        XCTAssertEqual(TypographyStyle(
            rawValue: try XCTUnwrap(defaults.string(forKey: TypographyStyle.storageKey))),
            .magazineCutout)
        XCTAssertEqual(TypographyFont(
            rawValue: try XCTUnwrap(defaults.string(forKey: TypographyFont.storageKey))),
            .cinematic)
        XCTAssertEqual(TypographyStyle.storageKey, "karaokeTypography")
        XCTAssertEqual(TypographyFont.storageKey, "story.lyricTypography")
    }

    func testPresetWithoutFontDecodesWithDefaultFont() throws {
        let json = Data(#"{"style":"kinetic","audioReaction":"off"}"#.utf8)
        let preset = try JSONDecoder().decode(TypographyPreset.self, from: json)
        XCTAssertEqual(preset.style, .kinetic)
        XCTAssertEqual(preset.font, .classic)
        XCTAssertEqual(preset, TypographyPreset(style: .kinetic))
    }

    func testFontAndStyleRoundTrip() throws {
        for style in TypographyStyle.allCases {
            for font in TypographyFont.allCases {
                let preset = TypographyPreset.current(style: style, font: font)
                let decoded = try JSONDecoder().decode(
                    TypographyPreset.self, from: JSONEncoder().encode(preset))
                XCTAssertEqual(decoded, preset)
                XCTAssertEqual(decoded.audioReaction, .off)
            }
        }
    }

    // MARK: No lossy projection

    func testExtendedStylesSurvivePackagesInsteadOfBecomingNeon() throws {
        let cyber = try XCTUnwrap(CreativePresetCatalog.experience(for: "cyber-night"))
        XCTAssertEqual(cyber.typographyPreset.style, .glitch)
        XCTAssertEqual(cyber.composition.program.preset.typographyStyle, .glitch)
        let decoded = try JSONDecoder().decode(
            CreativePresetPackage.self, from: JSONEncoder().encode(cyber.package))
        XCTAssertEqual(decoded, cyber.package)
        XCTAssertEqual(decoded.typographyPreset.style, .glitch)
    }

    func testPackagesAuthoredBeforeStage10BStillValidate() throws {
        // Old packages recorded glitch/kinetic/minimal as .neon in the preset.
        let program = CreativePresetCatalog.program(for: "night-drive")
        XCTAssertEqual(program.preset.typographyStyle, .neon)
        let timeline = try CompositionTimeline(
            sourceStart: 0, playbackSpeed: 1, duration: 15)
        let composition = try CreativeSnapshotAdapter.wrap(program, timeline: timeline)
        for extended in [TypographyStyle.glitch, .kinetic, .minimal] {
            let legacy = try CreativePresetPackage(
                id: composition.id, name: composition.name, author: "Before10B",
                composition: composition,
                typographyPreset: TypographyPreset(style: extended))
            XCTAssertEqual(try JSONDecoder().decode(
                CreativePresetPackage.self, from: JSONEncoder().encode(legacy)), legacy)
        }
        // A genuine mismatch is still rejected.
        XCTAssertThrowsError(try CreativePresetPackage(
            id: composition.id, name: composition.name, author: "Mismatch",
            composition: composition,
            typographyPreset: TypographyPreset(style: .magazineCutout)))
    }

    // MARK: App = Story

    func testStoryFreezesTheAppTypographyPreset() throws {
        for style in TypographyStyle.allCases {
            for font in fonts {
                for reactive in [false, true] {
                    let story = try request(style: style, font: font, reactive: reactive)
                    XCTAssertEqual(story.typographyPreset,
                                   .current(style: style, font: font))
                    XCTAssertEqual(story.typography, font)
                    XCTAssertEqual(story.typographyPreset.audioReaction, .off,
                                   "The live karaoke resolves without audio features")
                }
            }
        }
    }

    func testStoryResolvesTheSameFrameAsTheApp() throws {
        for style in TypographyStyle.allCases {
            for font in fonts {
                for reactive in [false, true] {
                    let story = try request(style: style, font: font, reactive: reactive)
                    let grid = StoryRenderTimeline(request: story, profile: .balanced)
                    // lyricTime = 1.5 + elapsed: indices 10...89 cover the whole
                    // active line, including every word boundary.
                    for index in stride(from: 10, through: 89, by: 1) {
                        let renderFrame = grid.frame(index: index)
                        let scene = StorySceneView(
                            request: story, artwork: nil, frame: renderFrame)
                        let exported = try XCTUnwrap(
                            scene.typographyFrame,
                            "\(style) \(font) reactive=\(reactive) index=\(index)")
                        XCTAssertEqual(
                            exported,
                            appFrame(style: style, font: font,
                                     at: renderFrame.lyricTime),
                            "\(style) \(font) reactive=\(reactive) index=\(index)")
                    }
                }
            }
        }
    }

    func testStoryNoLongerForcesNeon() throws {
        let story = try request(style: .magazineCutout, font: .classic)
        let renderFrame = StoryRenderTimeline(request: story, profile: .balanced)
            .frame(index: 30)
        let frame = try XCTUnwrap(StorySceneView(
            request: story, artwork: nil, frame: renderFrame).typographyFrame)
        XCTAssertEqual(frame.preset.style, .magazineCutout)
        XCTAssertNotNil(frame.word(id: 0)?.magazine)

        let glitch = try request(style: .glitch, font: .mono)
        let glitchFrame = try XCTUnwrap(StorySceneView(
            request: glitch, artwork: nil,
            frame: StoryRenderTimeline(request: glitch, profile: .balanced)
                .frame(index: 30)).typographyFrame)
        let active = try XCTUnwrap(glitchFrame.activeWordID)
        let state = try XCTUnwrap(glitchFrame.animation(for: active))
        XCTAssertGreaterThan(state.effectIntensity, 0)
    }

    func testPreviewSuppliedFrameAndExportAgreeForExtendedStyles() throws {
        for style in [TypographyStyle.glitch, .kinetic, .magazineCutout] {
            let story = try request(style: style, font: .classic, reactive: true)
            let composition = try XCTUnwrap(story.visualComposition)
            let grid = StoryRenderTimeline(request: story, profile: .balanced)
            for index in [12, 30, 55, 80] {
                let renderFrame = grid.frame(index: index)
                let layer = TypographyLayer.forStory(
                    lines: story.lines, lyricTime: renderFrame.lyricTime,
                    lyricOffset: story.lyricOffset, preset: story.typographyPreset)
                let preview = StorySceneView(
                    request: story, artwork: nil,
                    frame: grid.frame(at: renderFrame.elapsed),
                    resolvedCompositionFrame: CompositionRuntime(
                        composition: composition).frame(
                            at: renderFrame.elapsed, audioTimeline: nil,
                            typography: layer))
                let export = StorySceneView(
                    request: story, artwork: nil, frame: renderFrame)
                XCTAssertEqual(preview.typographyFrame, export.typographyFrame)
                XCTAssertNotNil(export.typographyFrame)
            }
        }
    }

    // MARK: Pixels

    @MainActor
    func testStoryPixelsFollowTheSelectedStyle() throws {
        // Cover background with a flat artwork: no Metal, only typography differs.
        let artwork = UIGraphicsImageRenderer(size: CGSize(width: 32, height: 32))
            .image { context in
                UIColor(red: 0.1, green: 0.1, blue: 0.3, alpha: 1).setFill()
                context.fill(CGRect(x: 0, y: 0, width: 32, height: 32))
            }
        func pixels(_ style: TypographyStyle) throws -> [UInt8] {
            let story = try request(style: style, font: .classic, background: .cover)
            let profile = StoryEncodingProfile.economical
            let frame = StoryRenderTimeline(request: story, profile: profile)
                .frame(index: 20)
            return try bytes(StoryFrameRenderer.render(
                request: story, artwork: artwork, frame: frame, profile: profile))
        }
        XCTAssertNotEqual(try pixels(.neon), try pixels(.magazineCutout),
                          "Magazine Cutout must reach the exported frame")
    }

    private func bytes(_ image: CGImage) throws -> [UInt8] {
        var data = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let drawn = data.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress, width: image.width, height: image.height,
                bitsPerComponent: 8, bytesPerRow: image.width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0,
                                           width: image.width, height: image.height))
            return true
        }
        XCTAssertTrue(drawn)
        return data
    }
}
