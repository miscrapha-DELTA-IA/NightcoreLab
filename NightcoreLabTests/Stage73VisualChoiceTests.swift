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

    func testRestoreBuild72ClassicVisualChooserAndDirectCreatorStudio() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("NightcoreLab/Sources")
        let player = try String(contentsOf: root.appendingPathComponent("NowPlayingScreen.swift"),
                                encoding: .utf8)
        let chrome = try String(contentsOf: root.appendingPathComponent("EnvironmentBar.swift"),
                                encoding: .utf8)
        let content = try String(contentsOf: root.appendingPathComponent("ContentView.swift"),
                                 encoding: .utf8)
        XCTAssertTrue(player.contains("creator.openStudio"),
                      "Build 72's explicit Criar studio action must remain discoverable")
        XCTAssertTrue(player.contains("Picker(\"Ritmo visual\""))
        XCTAssertFalse(player.contains("onChooseVisual: openVisualChoice"),
                       "Build 73 unified chooser must not replace the Build 72 selector")
        XCTAssertTrue(chrome.contains("ThemeBoltButton(theme: $theme, microphoneActive: microphoneActive)"))
        XCTAssertTrue(chrome.contains("CreativeVisualTaxonomy.classicThemes"))
        XCTAssertTrue(chrome.contains("CreativeVisualTaxonomy.materialThemes"))
        XCTAssertTrue(chrome.contains("CreativeVisualTaxonomy.gnarlyModes"))
        XCTAssertTrue(content.contains("MusicControlPage.stems"))
        XCTAssertTrue(content.contains("StemMixerControls(audio: audio)"))
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
