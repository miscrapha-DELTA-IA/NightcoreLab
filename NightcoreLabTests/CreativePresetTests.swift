import Foundation
import XCTest
@testable import NightcoreLab

final class CreativePresetTests: XCTestCase {
    func testCreationAndEqualityWithExistingTypes() {
        let visual = VisualPreset(
            background: .marble,
            shaderParameters: .init(timeScale: 0.6, distortion: 0.8, glow: 0.4),
            intensity: 0.9, motion: 0.2
        )
        let preset = CreativePreset(
            id: "acid-magazine", name: "Acid Magazine", theme: .acid,
            typographyStyle: .magazineCutout, visualStyle: visual,
            audioReaction: .subtle
        )
        XCTAssertEqual(preset.id, "acid-magazine")
        XCTAssertEqual(preset.theme, .acid)
        XCTAssertEqual(preset.typographyStyle, .magazineCutout)
        XCTAssertEqual(preset.visualStyle.background, .marble)
        XCTAssertEqual(preset, CreativePreset(
            id: preset.id, name: preset.name, theme: preset.theme,
            typographyStyle: preset.typographyStyle, visualStyle: visual,
            audioReaction: .subtle))
        XCTAssertNotEqual(preset, CreativePreset(
            id: preset.id, name: preset.name, theme: .cyber,
            typographyStyle: preset.typographyStyle, visualStyle: visual,
            audioReaction: .subtle))
    }

    func testCodableRoundTripPreservesAllSeventeenExistingThemes() throws {
        for theme in AppTheme.allCases {
            let preset = CreativePreset.current(
                theme: theme, typographyStyle: .neon, playerBackground: .turbulent)
            let bytes = try JSONEncoder().encode(preset)
            let decoded = try JSONDecoder().decode(CreativePreset.self, from: bytes)
            XCTAssertEqual(decoded, preset)
            XCTAssertEqual(decoded.audioReaction, .off)
            XCTAssertEqual(decoded.visualStyle.background, .marble)
        }
    }

    func testPersistenceCanUseUserDefaultsWithoutNewStateManager() throws {
        let name = "creative.foundation.tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }

        let preset = CreativePreset(
            id: "saved", name: "Magazine", theme: .noir,
            typographyStyle: .magazineCutout,
            visualStyle: VisualPreset(background: .blurredArtwork),
            audioReaction: .off)
        defaults.set(try JSONEncoder().encode(preset), forKey: "futureCreativePreset")

        let reopened = try XCTUnwrap(UserDefaults(suiteName: name))
        let data = try XCTUnwrap(reopened.data(forKey: "futureCreativePreset"))
        XCTAssertEqual(try JSONDecoder().decode(CreativePreset.self, from: data), preset)
    }

    func testUnknownThemeIsRejectedNotSilentlyChanged() throws {
        let original = CreativePreset.current(
            theme: .acid, typographyStyle: .neon, playerBackground: .sharp)
        let data = try JSONEncoder().encode(original)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        json["theme"] = "unknown-theme"
        let modified = try JSONSerialization.data(withJSONObject: json)
        XCTAssertThrowsError(try JSONDecoder().decode(CreativePreset.self, from: modified))
    }

    func testVisualPresetUsesExistingBackgroundStylesAndClampsParameters() throws {
        let backgrounds: [(PlayerBackgroundStyle, VisualPreset.Background)] = [
            (.blurred, .blurredArtwork), (.sharp, .sharpArtwork),
            (.marquee, .marqueeArtwork), (.turbulent, .marble)
        ]
        for (existing, expected) in backgrounds {
            XCTAssertEqual(VisualPreset.Background(existing: existing), expected)
        }
        let preset = VisualPreset(
            background: .nativeTurbulence,
            shaderParameters: .init(timeScale: 5, distortion: -.infinity, glow: 1.2),
            intensity: -4, motion: 12)
        XCTAssertEqual(preset.shaderParameters.timeScale, 1)
        XCTAssertEqual(preset.shaderParameters.distortion, 0)
        XCTAssertEqual(preset.shaderParameters.glow, 1)
        XCTAssertEqual(preset.intensity, 0)
        XCTAssertEqual(preset.motion, 1)
        XCTAssertEqual(try JSONDecoder().decode(VisualPreset.self, from:
            JSONEncoder().encode(preset)), preset)
    }

    func testSnapshotCapturesCurrentValuesWithoutMutatingPlayer() {
        let track = Track(id: "abcdefghijk", title: "Demo", thumbnailURL: nil)
        let timestamp = Date(timeIntervalSince1970: 1_700_000_000)
        let snapshot = CreativeSnapshot.capture(
            track: track, theme: .ultrablack, typographyStyle: .magazineCutout,
            playerBackground: .marquee, playbackTime: 34.5, marblePhase: 4.2,
            isPlaying: true, capturedAt: timestamp)
        XCTAssertEqual(snapshot.track, track)
        XCTAssertEqual(snapshot.theme, .ultrablack)
        XCTAssertEqual(snapshot.preset.typographyStyle, .magazineCutout)
        XCTAssertEqual(snapshot.preset.visualStyle.background, .marqueeArtwork)
        XCTAssertEqual(snapshot.visualState.playbackTime, 34.5)
        XCTAssertEqual(snapshot.visualState.marblePhase, 4.2)
        XCTAssertTrue(snapshot.visualState.isPlaying)
        XCTAssertEqual(snapshot.capturedAt, timestamp)
    }

    func testSnapshotSanitizesInvalidTimeForFutureRenderers() {
        let state = CreativeSnapshot.VisualState(
            playbackTime: .infinity, marblePhase: -.infinity, isPlaying: false)
        XCTAssertEqual(state.playbackTime, 0)
        XCTAssertEqual(state.marblePhase, 0)
    }
}
