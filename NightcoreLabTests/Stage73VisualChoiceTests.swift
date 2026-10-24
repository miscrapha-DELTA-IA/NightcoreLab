import Foundation
import XCTest
@testable import NightcoreLab

@MainActor
final class Stage73VisualChoiceTests: XCTestCase {
    func testStandaloneThemeRemovesInvisiblePreviousExperience() {
        XCTAssertEqual(VisualChoiceResolver.standalonePreset(for: .xeroxSerpentine),
                       CreativePresetCatalog.defaultID)
        XCTAssertEqual(VisualChoiceResolver.standalonePreset(for: .cyber),
                       CreativePresetCatalog.defaultID)
        let pure = VisualChoiceResolver.summary(
            theme: .xeroxSerpentine, experienceID: CreativePresetCatalog.defaultID)
        XCTAssertTrue(pure.contains("visual independente"))
        XCTAssertFalse(pure.contains("Vector Drift"))
    }

    func testExperienceOnProceduralGnarlyGetsVisibleThemeInsteadOfHiddenGeometry() {
        XCTAssertEqual(VisualChoiceResolver.baseThemeForExperience(current: .gnarly),
                       .cyber)
        XCTAssertEqual(VisualChoiceResolver.baseThemeForExperience(current: .gnarlyStrata),
                       .cyber)
        XCTAssertEqual(VisualChoiceResolver.baseThemeForExperience(current: .gnarlyOrganism),
                       .cyber)
        XCTAssertEqual(VisualChoiceResolver.baseThemeForExperience(current: .xeroxSerpentine),
                       .xeroxSerpentine)
        let mixed = VisualChoiceResolver.summary(
            theme: .xeroxSerpentine, experienceID: "gnarly-exp-vector-drift-2000")
        XCTAssertTrue(mixed.contains("Vector Drift"))
        XCTAssertTrue(mixed.contains("Xerox Serpentine"))
    }

    func testOriginalGnarlyShowsItsStandaloneIdentity() {
        let name = VisualChoiceResolver.summary(
            theme: .gnarly, experienceID: "gnarly-exp-vector-drift-2000")
        XCTAssertTrue(name.contains("modo autônomo"))
        XCTAssertFalse(name.contains("Vector Drift"))
    }

    func testCreativeAudioLevelsReleaseSmoothlyWithoutTimingStalls() {
        let smoothing = CreativeVisualEnvelope()
        let t = Date(timeIntervalSince1970: 500)
        let loud = LiveAudioLevels(rms: 1, bass: 1, mid: 1,
                                   onset: 1, beatPulse: 1, songEnergy: 1)
        XCTAssertEqual(smoothing.advance(date: t, levels: loud,
                                         mode: .responsive).bass, 0)
        let first = smoothing.advance(date: t.addingTimeInterval(1.0/60),
                                      levels: loud, mode: .responsive)
        XCTAssertGreaterThan(first.bass, 0)
        XCTAssertLessThan(first.bass, 1)
        let quiet = smoothing.advance(date: t.addingTimeInterval(2.0/60),
                                      levels: .silence, mode: .responsive)
        XCTAssertGreaterThan(quiet.bass, 0)
        XCTAssertLessThan(quiet.bass, first.bass)
        XCTAssertEqual(smoothing.advance(
            date: t.addingTimeInterval(3.0/60),
            levels: loud, mode: .off), .silence)
    }

    func testStage74NoCreateShortcutOverlapAndAdvancedControlsRemainAccessible() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("NightcoreLab/Sources")
        let player = try String(contentsOf: root.appendingPathComponent("NowPlayingScreen.swift"),
                                encoding: .utf8)
        let chrome = try String(contentsOf: root.appendingPathComponent("EnvironmentBar.swift"),
                                encoding: .utf8)
        let picker = try String(contentsOf: root.appendingPathComponent("Creative/VisualChoiceSheet.swift"),
                                encoding: .utf8)
        XCTAssertFalse(player.contains("creator.openStudio"),
                       "No redundant Criar button should collide with top-right Share")
        // Scope the overlap check to the player's outer chrome only.
        // The player card itself intentionally has its own top-aligned overlay.
        let chromeStart = try XCTUnwrap(player.range(of: ".environment(liveUniforms)"))
        let leadingBar = try XCTUnwrap(player.range(
            of: ".overlay(alignment: .topLeading) {",
            range: chromeStart.upperBound..<player.endIndex))
        let chromeBeforeLeading = player[chromeStart.upperBound..<leadingBar.lowerBound]
        XCTAssertFalse(chromeBeforeLeading.contains(".overlay(alignment: .top) {"),
                       "No extra centered toolbar can cover the share controls")
        XCTAssertTrue(player.contains(".overlay(alignment: .topTrailing) {"))
        XCTAssertTrue(player.contains("ShareButton("))
        XCTAssertTrue(player.contains("onChooseVisual: openVisualChoice"))
        XCTAssertTrue(chrome.contains("Text(\"Visual\")"))
        XCTAssertTrue(chrome.contains("visual.openPicker"))
        XCTAssertTrue(picker.contains("visual.openAdvanced"))
        XCTAssertTrue(player.contains("creatorRoute.isPresented = true"),
                      "Pads, loops and fine controls remain accessible through Visual")
    }

    func testSubtleReactionCannotCreateBiggerSpikeThanIntenseMode() {
        let base = Date(timeIntervalSince1970: 1_000)
        let heavy = LiveAudioLevels(rms: 0.7, bass: 1, mid: 1,
                                    onset: 1, beatPulse: 1, songEnergy: 1)
        let soft = CreativeVisualEnvelope(), hard = CreativeVisualEnvelope()
        _ = soft.advance(date: base, levels: heavy, mode: .subtle)
        _ = hard.advance(date: base, levels: heavy, mode: .responsive)
        let next = base.addingTimeInterval(1.0/30)
        let s = soft.advance(date: next, levels: heavy, mode: .subtle)
        let h = hard.advance(date: next, levels: heavy, mode: .responsive)
        XCTAssertLessThan(s.bass, h.bass)
        XCTAssertLessThan(s.onset, h.onset)
    }
}
