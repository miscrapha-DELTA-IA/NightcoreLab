import XCTest
@testable import NightcoreLab

final class PanelSystemTests: XCTestCase {
    @MainActor
    private func withDefaults(_ body: (UserDefaults) -> Void) {
        let suite = "PanelSystemTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        body(defaults)
    }

    @MainActor
    func testNewInstallShowsAllPanelsWithoutZen() {
        withDefaults { defaults in
            let store = PanelStore(defaults: defaults)
            XCTAssertTrue(store.hidden.isEmpty)
            XCTAssertFalse(store.isZen)
            for id in PanelID.allCases { XCTAssertTrue(store.isVisible(id)) }
        }
    }

    @MainActor
    func testLegacyPreferencesMergeAndMigrateOnlyOnce() {
        withDefaults { defaults in
            defaults.set(["lyrics", "unknown"], forKey: "ui.hiddenPanels")
            defaults.set(false, forKey: "visibleDiscover")
            defaults.set(false, forKey: "visibleQueue")
            defaults.set(true, forKey: "visiblePresets")
            defaults.set(true, forKey: "isZenMode")
            let store = PanelStore(defaults: defaults)
            XCTAssertEqual(store.hidden, [.lyrics])
            XCTAssertFalse(store.isZen)
            for key in ["visibleDiscover", "visibleQueue", "visiblePresets", "isZenMode"] {
                XCTAssertNil(defaults.object(forKey: key))
            }
            store.setVisible(true, for: .discover)
            let restored = PanelStore(defaults: defaults)
            XCTAssertEqual(restored.hidden, [.lyrics])
        }
    }

    @MainActor
    func testAllSixLegacyHiddenPanelsAreMigrated() {
        withDefaults { defaults in
            let keys = ["visibleDiscover", "visibleQueue", "visiblePlayback",
                        "visiblePresets", "visibleControls", "visibleExport"]
            for key in keys { defaults.set(false, forKey: key) }
            let store = PanelStore(defaults: defaults)
            XCTAssertEqual(store.hidden, [.presets, .controls, .export])
            for key in keys { XCTAssertNil(defaults.object(forKey: key)) }
        }
    }

    @MainActor
    func testVisibilityAndDensityLeaveExpansionAndHistoryIntact() {
        withDefaults { defaults in
            let keys = ["showDiscover", "showQueue", "showPlaybackDetails",
                        "showPresets", "showAudioControls", "showExport"]
            for (index, key) in keys.enumerated() { defaults.set(index.isMultiple(of: 2), forKey: key) }
            defaults.set(Data([1, 2, 3]), forKey: "omnibox.playHistory")
            let store = PanelStore(defaults: defaults)
            for id in PanelID.allCases { store.toggle(id); store.toggle(id) }
            for density in PanelDensity.allCases { store.apply(density) }
            store.showAll()
            for (index, key) in keys.enumerated() {
                XCTAssertEqual(defaults.bool(forKey: key), index.isMultiple(of: 2))
            }
            XCTAssertEqual(defaults.data(forKey: "omnibox.playHistory"), Data([1, 2, 3]))
        }
    }

    @MainActor
    func testZenMasksWithoutPersistingOrChangingChoices() {
        withDefaults { defaults in
            let store = PanelStore(defaults: defaults)
            store.toggle(.queue)
            let saved = defaults.stringArray(forKey: "ui.hiddenPanels")
            store.setZen(true)
            for id in PanelID.allCases { XCTAssertFalse(store.isVisible(id)) }
            XCTAssertEqual(store.hidden, [.queue])
            XCTAssertEqual(defaults.stringArray(forKey: "ui.hiddenPanels"), saved)
            store.setZen(false)
            XCTAssertTrue(store.isVisible(.omnibox))
            XCTAssertFalse(store.isVisible(.queue))
            store.setZen(true)
            XCTAssertFalse(PanelStore(defaults: defaults).isZen)
        }
    }

    @MainActor
    func testExplicitVisibilityExitsZenAndIsIdempotent() {
        withDefaults { defaults in
            let store = PanelStore(defaults: defaults)
            store.setZen(true)
            store.setVisible(false, for: .omnibox)
            store.setVisible(false, for: .omnibox)
            XCTAssertFalse(store.isZen)
            XCTAssertEqual(store.hidden, [.omnibox])
            store.setVisible(true, for: .omnibox)
            XCTAssertTrue(store.hidden.isEmpty)
        }
    }

    @MainActor
    func testDensityPresetsAndShowAllRecoverHiddenPanels() {
        withDefaults { defaults in
            let store = PanelStore(defaults: defaults)
            store.apply(.balanced)
            XCTAssertEqual(Set(PanelID.mainPanels.filter { store.isVisible($0) }),
                           [.header, .player, .omnibox, .controls])
            store.apply(.listen)
            XCTAssertEqual(Set(PanelID.mainPanels.filter { store.isVisible($0) }), [.player, .presets, .controls])
            XCTAssertTrue(store.isVisible(.lyrics))
            XCTAssertTrue(store.isVisible(.themes))
            XCTAssertEqual(PanelStore(defaults: defaults).hidden, store.hidden)
            store.apply(.discover)
            XCTAssertTrue(store.hidden.isEmpty)
            for id in PanelID.allCases { store.setVisible(false, for: id) }
            store.setZen(true)
            store.showAll()
            XCTAssertTrue(store.hidden.isEmpty)
            XCTAssertFalse(store.isZen)
        }
    }

    @MainActor
    func testHiddenPanelsOfferARecoverableCountWithoutChangingUnrelatedState() {
        withDefaults { defaults in
            let store = PanelStore(defaults: defaults)
            defaults.set("keep-playing", forKey: "lastSearchQuery")
            store.setVisible(false, for: .presets)
            store.setVisible(false, for: .export)
            XCTAssertEqual(store.hiddenCount(in: PanelID.mainPanels), 2)
            XCTAssertEqual(store.hiddenCount(in: PanelID.karaokePanels), 0)

            store.showAll()
            XCTAssertEqual(store.hiddenCount(in: PanelID.mainPanels), 0)
            XCTAssertEqual(defaults.string(forKey: "lastSearchQuery"), "keep-playing")
            XCTAssertTrue(PanelStore(defaults: defaults).hidden.isEmpty)
        }
    }

    @MainActor
    func testHeaderCanBeHiddenAndRestoredAlongsideOtherPanelsInOneAction() {
        withDefaults { defaults in
            let store = PanelStore(defaults: defaults)
            XCTAssertTrue(PanelID.mainPanels.contains(.header))
            store.hideAll(in: PanelID.mainPanels)
            XCTAssertFalse(store.isVisible(.header))
            XCTAssertFalse(store.isVisible(.player))
            XCTAssertEqual(store.hiddenCount(in: PanelID.mainPanels), PanelID.mainPanels.count)
            store.apply(.balanced)
            XCTAssertTrue(store.isVisible(.header))
            XCTAssertTrue(store.isVisible(.player))
            XCTAssertFalse(store.isVisible(.export))
            store.showAll()
            XCTAssertTrue(store.isVisible(.export))
            XCTAssertTrue(PanelStore(defaults: defaults).isVisible(.header))
        }
    }

    @MainActor
    func testObsoletePlaybackVisibilityNeverHidesMergedPlayer() {
        withDefaults { defaults in
            defaults.set(["playback", "presets"], forKey: "ui.hiddenPanels")
            defaults.set(false, forKey: "visiblePlayback")
            let store = PanelStore(defaults: defaults)
            XCTAssertTrue(store.isVisible(.player))
            XCTAssertTrue(store.isVisible(.header))
            XCTAssertFalse(store.isVisible(.presets))
            XCTAssertNil(defaults.object(forKey: "visiblePlayback"))
            XCTAssertFalse((defaults.stringArray(forKey: "ui.hiddenPanels") ?? []).contains("playback"))
        }
    }

    @MainActor
    func testDiscoveryWorkspaceBulkToggleUpdatesAllPanelsAndKeepsUnrelatedChoices() {
        withDefaults { defaults in
            let store = PanelStore(defaults: defaults)
            XCTAssertEqual(PanelID.discoveryPanels, [.omnibox])
            XCTAssertEqual(PanelID.audioPanels, [.presets, .controls])
            store.setVisible(false, for: PanelID.discoveryPanels)
            XCTAssertEqual(store.hiddenCount(in: PanelID.discoveryPanels), 1)
            XCTAssertTrue(store.isVisible(.player))
            XCTAssertTrue(store.isVisible(.presets))
            XCTAssertTrue(store.isVisible(.controls))
            store.setVisible(true, for: PanelID.discoveryPanels)
            XCTAssertEqual(store.hiddenCount(in: PanelID.discoveryPanels), 0)
            XCTAssertTrue(PanelStore(defaults: defaults).hidden.isEmpty)
        }
    }

    @MainActor
    func testEyeControlsOnlyBuscaWithoutChangingDiscoveryOrQueue() {
        withDefaults { defaults in
            defaults.set(["discover", "queue"], forKey: "ui.hiddenPanels")
            let store = PanelStore(defaults: defaults)
            XCTAssertEqual(PanelID.discoveryPanels, [.omnibox])
            XCTAssertTrue(PanelID.mainPanels.contains(.omnibox))
            XCTAssertFalse(PanelID.mainPanels.contains(.discover))
            XCTAssertFalse(PanelID.mainPanels.contains(.queue))
            XCTAssertTrue(store.isVisible(.discover), "Legacy eye choices must not hide recommendations forever")
            XCTAssertTrue(store.isVisible(.queue), "Legacy eye choices must not hide the queue forever")
            store.setVisible(false, for: PanelID.discoveryPanels)
            XCTAssertFalse(store.isVisible(.omnibox))
            XCTAssertTrue(store.isVisible(.discover))
            XCTAssertTrue(store.isVisible(.queue))
            store.setVisible(true, for: PanelID.discoveryPanels)
            XCTAssertTrue(store.isVisible(.omnibox))
            store.apply(.listen)
            XCTAssertTrue(store.isVisible(.discover))
            XCTAssertTrue(store.isVisible(.queue))
            XCTAssertFalse(store.isVisible(.omnibox))
        }
    }

    func testCompleteOmniboxVisibilityKeepsExistingPosition() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("NightcoreLab/Sources")
        let nowPlaying = try String(contentsOf: root.appendingPathComponent("NowPlayingScreen.swift"))
        let search = try String(contentsOf: root.appendingPathComponent("SearchView.swift"))
        XCTAssertTrue(nowPlaying.contains(".offset(y: card.size.height - 3)"),
                      "Existing drawer position must be unchanged")
        XCTAssertTrue(nowPlaying.contains(".hideablePanel(.omnibox, edge: .top)"),
                      "Busca must hide the complete drawer, including the handle")
        XCTAssertFalse(search.contains(".hideablePanel(.omnibox, edge: .top)"),
                       "Visibility must wrap the container rather than just its text field")
        let content = try String(contentsOf: root.appendingPathComponent("ContentView.swift"))
        XCTAssertTrue(content.contains("musicWorkspace(focusRequest: 0)\n                            .hideablePanel(.omnibox, edge: .top)"),
                      "The empty-player omnibox must obey the same preference")
        XCTAssertTrue(nowPlaying.contains("searchDrawer.isOpen && panels.isVisible(.omnibox) ? 360 : 0"),
                      "A hidden open drawer must not reserve empty space")
        XCTAssertFalse(nowPlaying.contains("panels.setVisible(true, for: .omnibox)"),
                       "Opening the drawer must not override the eye's hidden preference")
    }

    @MainActor
    func testAudioWorkspaceBulkVisibilityDoesNotHideMusicDiscovery() {
        withDefaults { defaults in
            let store = PanelStore(defaults: defaults)
            store.setVisible(false, for: PanelID.audioPanels)
            XCTAssertEqual(store.hiddenCount(in: PanelID.audioPanels), 2)
            XCTAssertTrue(store.isVisible(.omnibox))
            XCTAssertTrue(store.isVisible(.queue))
            store.setVisible(true, for: .presets)
            XCTAssertEqual(store.hiddenCount(in: PanelID.audioPanels), 1)
            XCTAssertFalse(store.isVisible(.controls))
            store.setVisible(true, for: PanelID.audioPanels)
            XCTAssertTrue(PanelStore(defaults: defaults).hidden.isEmpty)
        }
    }

    @MainActor
    func testBatchVisibilityAlwaysExitsZenWithoutLosingPreviousPreferences() {
        withDefaults { defaults in
            let store = PanelStore(defaults: defaults)
            store.setVisible(false, for: .header)
            store.setZen(true)
            store.setVisible(false, for: [.omnibox, .queue])
            XCTAssertFalse(store.isZen)
            XCTAssertFalse(store.isVisible(.header))
            XCTAssertFalse(store.isVisible(.queue))
            XCTAssertTrue(store.isVisible(.player))
            store.setVisible(true, for: [.omnibox, .queue])
            XCTAssertEqual(store.hidden, [.header])
        }
    }

    @MainActor
    func testSearchRevealIsTemporaryAndNeverWritesPreferences() {
        withDefaults { defaults in
            let store = PanelStore(defaults: defaults)
            store.setVisible(false, for: .discover)
            let saved = defaults.stringArray(forKey: "ui.hiddenPanels")
            XCTAssertFalse(PanelPresentation.showsDiscover(hidden: store.hidden, isZen: false, searchActive: false))
            XCTAssertTrue(PanelPresentation.showsDiscover(hidden: store.hidden, isZen: false, searchActive: true))
            XCTAssertFalse(PanelPresentation.showsDiscover(hidden: store.hidden, isZen: false, searchActive: false))
            XCTAssertEqual(defaults.stringArray(forKey: "ui.hiddenPanels"), saved)
        }
    }

    func testSearchCannotRevealThroughZenOrHiddenOmnibox() {
        XCTAssertFalse(PanelPresentation.showsDiscover(hidden: [], isZen: true, searchActive: true))
        XCTAssertFalse(PanelPresentation.showsDiscover(hidden: [.omnibox, .discover], isZen: false, searchActive: true))
        // Recommendations can still be visible without the search field.
        XCTAssertTrue(PanelPresentation.showsDiscover(hidden: [.omnibox], isZen: false, searchActive: false))
    }

    func testSearchExpansionIsTemporaryAndRespectsManualCollapse() {
        XCTAssertTrue(PanelPresentation.discoverExpanded(saved: false, searchActive: true, userOverride: nil))
        XCTAssertFalse(PanelPresentation.discoverExpanded(saved: false, searchActive: false, userOverride: nil))
        XCTAssertFalse(PanelPresentation.discoverExpanded(saved: true, searchActive: true, userOverride: false))
        XCTAssertTrue(PanelPresentation.discoverExpanded(saved: true, searchActive: false, userOverride: false))
    }
}
