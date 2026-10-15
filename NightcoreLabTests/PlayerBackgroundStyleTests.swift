import XCTest
@testable import NightcoreLab

final class PlayerBackgroundStyleTests: XCTestCase {
    func testOrganicResponsiveUsesExistingFoldUniformsWithoutBeatOrGeometryPulse() {
        let base = MaterialResolver.resolve(VisualMaterialCatalog.neonPulse, timestamp: 2)
        let quiet = MarbleLiveResponse.applyOrganic(base, energy: 0)
        let swell = MarbleLiveResponse.applyOrganic(base, energy: 1)
        XCTAssertEqual(quiet.parameters.beatPulse, 0)
        XCTAssertEqual(swell.parameters.beatPulse, 0)
        XCTAssertEqual(swell.parameters.warpAmount,
                       base.parameters.warpAmount * 1.20, accuracy: 0.000_001)
        XCTAssertEqual(swell.parameters.stripingMix, base.parameters.stripingMix)
        XCTAssertEqual(swell.parameters.distortion, base.parameters.distortion)
        XCTAssertGreaterThan(swell.parameters.brightnessBoost,
                             quiet.parameters.brightnessBoost)
        XCTAssertEqual(MarbleLiveResponse.apply(base, levels: .silence, mode: .off), base)
    }

    func testAllBackgroundModesAreExposed() {
        XCTAssertEqual(PlayerBackgroundStyle.allCases.count, 4)
        XCTAssertEqual(PlayerBackgroundStyle.turbulent.displayName, "Turbulent Displacement")
        XCTAssertEqual(PlayerBackgroundStyle.turbulent.symbolName, "waveform.path")
    }

    @MainActor
    func testActualPlayerBackgroundRoutesAllCuratedTexturesToMetal() {
        for id in ["neon-pulse", "agate-zebra", "void-gloss",
                   "terrazzo-magma", "airbrush-mirage",
                   "groove-ebru", "cymatic-rorschach"] {
            let card = PlayerBackgroundView(
                style: .blurred, imageURL: nil, theme: .cyber,
                material: CreativePresetCatalog.material(selection: id))
            XCTAssertEqual(card.effectiveStyle, .turbulent, id)
            XCTAssertTrue(card.renderedSurface.textured, id)
            XCTAssertEqual(card.renderedSurface.materialID, id)
            XCTAssertEqual(card.renderedSurface.paletteHex?.count, 5)
        }
        let cyber = PlayerBackgroundView(
            style: .turbulent, imageURL: nil, theme: .cyber,
            material: CreativePresetCatalog.material(selection: "cyber-night"))
        XCTAssertFalse(cyber.renderedSurface.textured)
    }

    func testCarouselIncludesFluidModeAndLoops() {
        XCTAssertEqual(PlayerBackgroundStyle.marquee.next, .turbulent)
        XCTAssertEqual(PlayerBackgroundStyle.turbulent.next, .blurred)
    }
}

final class MarbleThemeIntegrationTests: XCTestCase {
    func testMetalPaletteFollowsAppThemes() {
        XCTAssertEqual(MarbleTheme(appTheme: .acid), .acid)
        XCTAssertEqual(MarbleTheme(appTheme: .cyber), .cyber)
        XCTAssertEqual(MarbleTheme(appTheme: .crimson), .crimson)
        XCTAssertEqual(MarbleTheme(appTheme: .ultraviolet), .ultraviolet)
        XCTAssertEqual(MarbleTheme(appTheme: .solar), .solar)
        XCTAssertEqual(MarbleTheme(appTheme: .orchid), .orchid)
        XCTAssertEqual(MarbleTheme(appTheme: .sapphire), .sapphire)
        XCTAssertEqual(MarbleTheme(appTheme: .atomic), .atomic)
        XCTAssertEqual(MarbleTheme(appTheme: .lagoon), .lagoon)
        XCTAssertEqual(MarbleTheme(appTheme: .volt), .volt)
        XCTAssertEqual(MarbleTheme(appTheme: .prism), .prism)
        XCTAssertEqual(MarbleTheme(appTheme: .magma), .magma)
        XCTAssertEqual(MarbleTheme(appTheme: .noir), .noir)
        XCTAssertEqual(MarbleTheme(appTheme: .ultrapink), .ultrapink)
        XCTAssertEqual(MarbleTheme(appTheme: .ultraorange), .ultraorange)
        XCTAssertEqual(MarbleTheme(appTheme: .purewhite), .purewhite)
        XCTAssertEqual(MarbleTheme(appTheme: .ultrablack), .ultrablack)
    }

    /// Um novo AppTheme sem MarbleTheme correspondente voltaria silenciosamente ao Acid.
    func testEveryAppThemeHasItsOwnMarbleTheme() {
        XCTAssertEqual(MarbleTheme.allCases.count, AppTheme.allCases.count)
        for theme in AppTheme.allCases {
            XCTAssertEqual(MarbleTheme(appTheme: theme).rawValue, theme.rawValue,
                           "\(theme.displayName) não tem MarbleTheme correspondente")
        }
    }
}

/// Stage 24: one proven selector, with all other authored recipes archived.
final class Stage24LiveExperienceTests: XCTestCase {
    func testOnlyCyberNightThroughAtmosphericSmokeAreSelectable() {
        let ids = CreativePresetCatalog.selectableExperiences.map(\.id)
        XCTAssertEqual(ids, CreativePresetCatalog.liveExperienceIDs)
        XCTAssertEqual(ids.first, "cyber-night")
        XCTAssertEqual(ids.last, "atmospheric-smoke")
        XCTAssertEqual(ids.count, 7)
        for id in ["agate-zebra", "void-gloss", "terrazzo-magma",
                   "airbrush-mirage", "groove-ebru", "cymatic-rorschach"] {
            XCTAssertFalse(ids.contains(id))
            // Old shared presets and frozen export formats must still decode.
            XCTAssertNotNil(CreativePresetCatalog.selectedExperience(id: id))
            XCTAssertEqual(CreativePresetCatalog.liveSelection(id), "cyber-night")
        }
        XCTAssertEqual(CreativePresetCatalog.liveSelection("original"), "original")
    }

    @MainActor
    func testEveryLiveExperienceFollowsLightningBoltPalette() {
        for experience in CreativePresetCatalog.selectableExperiences {
            let material = experience.visualMaterial
            for theme in AppTheme.allCases {
                let next = theme.next
                let before = MarbleTheme(appTheme: theme).palette
                let after = MarbleTheme(appTheme: next).palette
                XCTAssertFalse(before.body == after.body && before.glow == after.glow,
                               "\(experience.id): \(theme) did not update its accent")
                let first = TurbulentMarbleView.shaderPalette(
                    materialID: material.id, theme: MarbleTheme(appTheme: theme),
                    authored: VisualMaterialCatalog.curatedPalettes[material.id]?.hex)
                let second = TurbulentMarbleView.shaderPalette(
                    materialID: material.id, theme: MarbleTheme(appTheme: next),
                    authored: VisualMaterialCatalog.curatedPalettes[material.id]?.hex)
                if material.id == "neon-pulse" {
                    XCTAssertEqual(first?.count, 5)
                    XCTAssertNotEqual(first?[1], second?[1])
                    XCTAssertNotEqual(first?[2], second?[2])
                } else {
                    XCTAssertNil(first, "Only Neon Pulse may use fixed textured stops in live UI")
                }
            }
        }
    }
}
