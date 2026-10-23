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
