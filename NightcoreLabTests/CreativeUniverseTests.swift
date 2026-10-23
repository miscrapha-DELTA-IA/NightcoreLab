import XCTest
import SwiftUI
@testable import NightcoreLab

final class CreativeUniverseTests: XCTestCase {
    func testExactlySixThemesSixExperiencesAndThreeProceduralModes() {
        let items = CreativeUniverseCatalog.entries
        XCTAssertEqual(items.count, 15)
        XCTAssertEqual(items.filter { $0.category == "theme" }.count, 6)
        XCTAssertEqual(items.filter { $0.category == "experience" }.count, 6)
        XCTAssertEqual(items.filter { $0.category == "procedural" }.count, 3)
        XCTAssertEqual(Set(items.map(\.id)).count, 15)
        XCTAssertEqual(Set(items.map(\.slug)).count, 15)
        XCTAssertTrue(items.allSatisfy { $0.palette.count == 3 })
        XCTAssertTrue(items.allSatisfy { !$0.references.isEmpty })
    }

    func testLegacyGnarlyAndExistingMarbleUnchanged() {
        XCTAssertNil(CreativeUniverseCatalog.lookID(theme: .gnarly,
                                                     materialID: "original-marble"))
        XCTAssertNil(CreativeUniverseCatalog.lookID(theme: .acid,
                                                     materialID: "neon-pulse"))
        XCTAssertEqual(CreativeUniverseCatalog.lookID(theme: .xeroxSerpentine,
                                                      materialID: "original-marble"), 1)
        XCTAssertEqual(CreativeUniverseCatalog.lookID(theme: .gnarlyStrata,
                                                      materialID: "original-marble"), 13)
        XCTAssertEqual(CreativeUniverseCatalog.lookID(theme: .gnarlyCompiler,
                                                      materialID: "original-marble"), 14)
        XCTAssertEqual(CreativeUniverseCatalog.lookID(theme: .gnarlyOrganism,
                                                      materialID: "original-marble"), 15)
        // Mode GNARLY is standalone: selecting an experience must not
        // overwrite a previously selected autonomous visual system.
        XCTAssertEqual(CreativeUniverseCatalog.lookID(
            theme: .gnarlyCompiler, materialID: "gnarly-exp-vector-drift-2000"), 14)
        XCTAssertEqual(CreativeUniverseCatalog.lookID(
            theme: .gnarlyStrata, materialID: "gnarly-exp-caustic-dissection"), 13)
        XCTAssertNil(CreativeUniverseCatalog.lookID(
            theme: .gnarly, materialID: "gnarly-exp-tectonic-mesh"))
    }

    func testAllSixExperiencesAreRealSelectableMaterials() {
        for entry in CreativeUniverseCatalog.experiences {
            let id = "gnarly-exp-" + entry.slug
            XCTAssertTrue(CreativePresetCatalog.isLiveExperience(id))
            XCTAssertEqual(CreativePresetCatalog.selectedExperience(id: id)?.visualMaterial.id, id)
            XCTAssertEqual(CreativeUniverseCatalog.lookID(theme: .acid, materialID: id),
                           entry.id)
        }
        XCTAssertEqual(Set(CreativePresetCatalog.liveExperienceIDs).count,
                       CreativePresetCatalog.liveExperienceIDs.count)
    }

    func testVisualTaxonomyPartitionsAllExistingThemeIDsWithoutChangingPersistence() {
        let classic = CreativeVisualTaxonomy.classicThemes
        let materials = CreativeVisualTaxonomy.materialThemes
        let modes = CreativeVisualTaxonomy.gnarlyModes
        XCTAssertEqual(materials.count, 6)
        XCTAssertEqual(modes.count, 4) // original Gnarly + three new modes
        let combined = classic + materials + modes
        XCTAssertEqual(combined.count, AppTheme.allCases.count)
        XCTAssertEqual(Set(combined), Set(AppTheme.allCases))
        XCTAssertEqual(CreativeVisualTaxonomy.nextTheme(after: .gnarly), classic[0])
        XCTAssertFalse(CreativeVisualTaxonomy.selectableThemes.contains(.gnarlyCompiler))
    }

    func testExperiencesReactToThemeWithoutReplacingLookIdentity() {
        for entry in CreativeUniverseCatalog.experiences {
            let selection = "gnarly-exp-" + entry.slug
            let cyan = CreativeUniverseCatalog.palette(
                id: entry.id, sourceTime: 15, duration: 160,
                artworkHue: nil, theme: .cyber)
            let solar = CreativeUniverseCatalog.palette(
                id: entry.id, sourceTime: 15, duration: 160,
                artworkHue: nil, theme: .solar)
            XCTAssertNotEqual(cyan, solar)
            XCTAssertEqual(CreativeUniverseCatalog.lookID(
                theme: .solar, materialID: selection), entry.id)
            XCTAssertFalse(CreativeUniverseCatalog.experienceDescription(
                slug: entry.slug).isEmpty)
        }
    }

    func testArtworkHueEntersOnlyProceduralPhaseAndRemainsReproducible() {
        let a = CreativeUniverseCatalog.palette(id: 13, sourceTime: 10,
                                                 duration: 100, artworkHue: 0.2)
        let b = CreativeUniverseCatalog.palette(id: 13, sourceTime: 10,
                                                 duration: 100, artworkHue: 0.2)
        let c = CreativeUniverseCatalog.palette(id: 13, sourceTime: 10,
                                                 duration: 100, artworkHue: 0.7)
        XCTAssertEqual(a.count, 3)
        XCTAssertEqual(a, b)
        XCTAssertNotEqual(a, c)
        let finalA = CreativeUniverseCatalog.palette(id: 13, sourceTime: 29,
                                                      duration: 100, artworkHue: 0.2)
        let finalB = CreativeUniverseCatalog.palette(id: 13, sourceTime: 29,
                                                      duration: 100, artworkHue: 0.7)
        XCTAssertEqual(finalA, finalB)
    }
}
