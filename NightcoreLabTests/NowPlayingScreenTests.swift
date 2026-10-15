import XCTest
@testable import NightcoreLab

final class NowPlayingScreenTests: XCTestCase {
    @MainActor
    func testSearchDrawerToggleAndFocusDoNotTouchPlayerTransport() {
        let audio = AudioEngineManager()
        let clock = audio.lyricsClock
        let generation = audio.scheduleGeneration
        var drawer = SearchDrawerState()
        XCTAssertFalse(drawer.isOpen)
        drawer.toggle()
        XCTAssertTrue(drawer.isOpen)
        drawer.openForSearch()
        XCTAssertEqual(drawer.focusRequest, 1)
        drawer.close()
        XCTAssertFalse(drawer.isOpen)
        XCTAssertTrue(clock === audio.lyricsClock)
        XCTAssertEqual(audio.scheduleGeneration, generation)
        XCTAssertFalse(audio.isPlaying)
    }

    @MainActor
    func testSelectingTrackCollapsesDrawerWithoutChangingTransport() {
        let audio = AudioEngineManager()
        let generation = audio.scheduleGeneration
        let clock = audio.lyricsClock
        var drawer = SearchDrawerState()
        drawer.openForSearch()
        let focus = drawer.focusRequest
        drawer.selectedTrack()
        XCTAssertFalse(drawer.isOpen)
        XCTAssertEqual(drawer.focusRequest, focus)
        XCTAssertEqual(audio.scheduleGeneration, generation)
        XCTAssertTrue(audio.lyricsClock === clock)
    }

    func testNewTrackIdentityReplacesCreatorAndShareHeader() {
        let artwork = URL(string: "https://example.com/new-cover.jpg")!
        let selected = Track(id: "new-track", title: "Singer - New Song",
                             thumbnailURL: artwork)
        let info = TrackInfo(track: selected, fileName: nil, coverURL: artwork)
        let snapshot = ShareSnapshot(trackID: info.id, title: info.title,
            artist: info.artist, artworkURL: info.coverURL, theme: .acid,
            visualStyle: .marble, marblePhase: 0, timestamp: .now)
        XCTAssertEqual(snapshot.trackID, selected.id)
        XCTAssertEqual(snapshot.title, selected.title)
        XCTAssertEqual(snapshot.artworkURL, artwork)
        XCTAssertEqual(info.coverURL, artwork)
    }

    func testPlayerOwnsDrawerAndMusicSelectionUsesExistingPlaybackPath() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("NightcoreLab/Sources")
        let player = try String(contentsOf: root.appendingPathComponent("NowPlayingScreen.swift"))
        let content = try String(contentsOf: root.appendingPathComponent("ContentView.swift"))
        XCTAssertTrue(player.contains("playerWithDrawer"))
        XCTAssertTrue(player.contains(".hideablePanel(.player, edge: .top)"))
        XCTAssertTrue(content.contains("searchDrawerContent: { focusRequest in musicWorkspace"))
        XCTAssertTrue(content.contains("playTrack(track)"))
        XCTAssertTrue(content.contains("searchDrawer.close()"))
    }

    func testIntegratedPlayerKeepsBackgroundStylesAvailable() {
        // The embedded card keeps using the prior four PlayerBackgroundStyle choices.
        XCTAssertEqual(PlayerBackgroundStyle.allCases.count, 4)
        XCTAssertTrue(PlayerBackgroundStyle.allCases.contains(.turbulent))
    }

    func testMapsYouTubeTrackAndParsesAvailableArtist() {
        let artwork = URL(string: "https://i.ytimg.com/vi/dQw4w9WgXcQ/hqdefault.jpg")
        let track = Track(id: "dQw4w9WgXcQ", title: "Example Artist - Example Track",
                          thumbnailURL: artwork)
        let info = TrackInfo(track: track, fileName: nil, coverURL: nil)

        XCTAssertEqual(info.id, track.id)
        XCTAssertEqual(info.title, track.title)
        XCTAssertEqual(info.artist, "Example Artist")
        XCTAssertEqual(info.coverURL, artwork)
    }

    func testLocalAudioDoesNotRequireYouTubeTrack() {
        let info = TrackInfo(track: nil, fileName: "Minha Faixa.mp3", coverURL: nil)
        XCTAssertEqual(info.id, "local:Minha Faixa.mp3")
        XCTAssertEqual(info.title, "Minha Faixa.mp3")
        XCTAssertEqual(info.artist, "Arquivo local")
        XCTAssertNil(info.coverURL)
    }

    func testEmptyPlayerHasStablePlaceholder() {
        let info = TrackInfo(track: nil, fileName: nil, coverURL: nil)
        XCTAssertEqual(info.id, "idle")
        XCTAssertEqual(info.title, "Nenhuma música")
    }

    func testNoArtistFallbackAndDownloadedCoverPreferred() {
        let original = URL(string: "https://example.org/original.png")
        let downloaded = URL(string: "https://example.org/cover.png")
        let track = Track(id: "dQw4w9WgXcQ", title: "Instrumental", thumbnailURL: original)
        let info = TrackInfo(track: track, fileName: "ignored", coverURL: downloaded)
        XCTAssertEqual(info.artist, "YouTube")
        XCTAssertEqual(info.coverURL, downloaded)
    }
}
