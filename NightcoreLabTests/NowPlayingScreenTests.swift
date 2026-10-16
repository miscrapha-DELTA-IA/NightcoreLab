import XCTest
@testable import NightcoreLab

final class NowPlayingScreenTests: XCTestCase {
    @MainActor
    func testDrawerMixIsInstantDeterministicAndAlwaysHasFifteenDistinctTracks() {
        let cached = Track(id: "cached-song", title: "Saved Song", thumbnailURL: nil)
        let discovery = Track(id: "discovered-song", title: "Discovered", thumbnailURL: nil)
        let first = DrawerSmartMix.resolve(history: [], cached: [cached],
                                           discovery: [discovery], current: nil)
        let second = DrawerSmartMix.resolve(history: [], cached: [cached],
                                            discovery: [discovery], current: nil)
        XCTAssertEqual(first, second)
        XCTAssertEqual(first.count, 15)
        XCTAssertEqual(Set(first.map(\.id)).count, 15)
        XCTAssertEqual(Array(first.map(\.id).prefix(2)), [cached.id, discovery.id])
        XCTAssertTrue(first.allSatisfy { $0.url.scheme == "https" && !$0.title.isEmpty })
    }

    @MainActor
    func testEmptyQueryShowsInstantRecentsAndQueueWhileSelectionWaitsForPlayback() throws {
        let played = Track(id: "played", title: "Recent Song", thumbnailURL: nil)
        let cached = Track(id: "cached", title: "Library Song", thumbnailURL: nil)
        let next = Track(id: "next", title: "Next Song", thumbnailURL: nil)
        var drawer = SearchDrawerState()
        drawer.toggle()
        XCTAssertTrue(DrawerQuickAccess.shouldShow(query: "  ", submittedQuery: nil))
        XCTAssertFalse(DrawerQuickAccess.shouldShow(query: "Song", submittedQuery: nil))
        XCTAssertFalse(DrawerQuickAccess.shouldShow(query: "", submittedQuery: "Song"))
        XCTAssertEqual(DrawerQuickAccess.recents(
            recent: [played], cached: [played, cached], current: played).map(\.id),
            ["played", "cached"])
        let queue = PlaybackQueue()
        queue.replace(with: [next], excluding: played.id)
        XCTAssertEqual(queue.upNextQueue.map(\.id), ["next"])
        drawer.beginSelection(trackID: next.id)
        XCTAssertTrue(drawer.isOpen, "Download must not hide the drawer")
        XCTAssertEqual(drawer.pendingTrackID, next.id)
        XCTAssertFalse(drawer.confirmPlayback(trackID: "stale"))
        XCTAssertTrue(drawer.confirmPlayback(trackID: next.id))
        XCTAssertFalse(drawer.isOpen)
        XCTAssertNil(drawer.pendingTrackID)
        XCTAssertTrue(queue.remove(next))
        XCTAssertTrue(queue.upNextQueue.isEmpty)

        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("NightcoreLab/Sources")
        let search = try String(contentsOf: root.appendingPathComponent("SearchView.swift"))
        XCTAssertTrue(search.contains("TOCADAS RECENTEMENTE"))
        XCTAssertTrue(search.contains("FILA A SEGUIR"))
        XCTAssertTrue(search.contains("searchDrawer.quickAccess"))
    }

    func testFailedDrawerSelectionKeepsDrawerOpenForRetry() {
        var drawer = SearchDrawerState()
        drawer.toggle()
        drawer.beginSelection(trackID: "network-track")
        XCTAssertTrue(drawer.selectionFailed(trackID: "network-track"))
        XCTAssertTrue(drawer.isOpen)
        XCTAssertNil(drawer.pendingTrackID)
    }

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
        XCTAssertTrue(content.contains("searchDrawer.confirmPlayback(trackID: trackID)"))
        XCTAssertTrue(content.contains("#selector(UIResponder.resignFirstResponder)"))
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

    @MainActor
    func testStage36MusicStemSwitcherAndUntruncatedHeaderContract() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("NightcoreLab/Sources")
        let content = try String(contentsOf: root.appendingPathComponent("ContentView.swift"),
                                 encoding: .utf8)
        let player = try String(contentsOf: root.appendingPathComponent("NowPlayingScreen.swift"),
                                encoding: .utf8)
        XCTAssertTrue(content.contains("NightcoreBrandLockup(theme: currentTheme)"))
        XCTAssertTrue(content.contains(".fixedSize(horizontal: true, vertical: false)"))
        XCTAssertTrue(content.contains(".layoutPriority(2)"))
        XCTAssertTrue(content.contains("v43 · "), "Stage 43 preserves the full Nightcore Lab lockup")
        let lockup = try String(contentsOf: root.appendingPathComponent("AppIconView.swift"), encoding: .utf8)
        XCTAssertTrue(lockup.contains("Text(\"Nightcore Lab\")"))
        XCTAssertTrue(lockup.contains(".fixedSize(horizontal: true, vertical: false)"))
        XCTAssertTrue(lockup.contains(".layoutPriority(2)"))
        XCTAssertFalse(lockup.contains(".minimumScaleFactor(0.75)"))
        XCTAssertTrue(content.contains("music.controlMode"))
        XCTAssertTrue(content.contains("MusicControlPage.stems"))
        XCTAssertTrue(content.contains("StemMixerControls(audio: audio)"))
        XCTAssertFalse(player.contains("StemMixerControls(audio: audio)"),
                       "Stem controls must not remain inside Criar")
        let mixer = try String(contentsOf: root.appendingPathComponent("StemMixerControls.swift"),
                               encoding: .utf8)
        XCTAssertTrue(mixer.contains("music.stemMixer"))
        XCTAssertTrue(mixer.contains("stem.reset"))
        XCTAssertTrue(mixer.contains("in: 0...2"))
    }

    @MainActor
    func testStage36FourDirectStemGainChangesNeverRestartTransport() {
        let audio = AudioEngineManager()
        let generation = audio.scheduleGeneration
        let initialEngine = audio.isAudioEngineRunning
        for kind in StemKind.allCases {
            audio.setStemLevel(kind, level: 0)
            XCTAssertEqual(audio.stemLevels[kind], 0)
            XCTAssertEqual(audio.liveStemEQGain(kind), 0, accuracy: 0.01)
            XCTAssertFalse(audio.stemsAvailable, "No fake isolation while four buffers prepare")
            audio.setStemLevel(kind, level: 2)
            XCTAssertEqual(audio.stemLevels[kind], 2)
            XCTAssertEqual(audio.liveStemEQGain(kind), 0, accuracy: 0.01)
            XCTAssertFalse(audio.stemsAvailable, "Live EQ stays neutral until real buffers exist")
        }
        XCTAssertEqual(audio.scheduleGeneration, generation)
        XCTAssertEqual(audio.isAudioEngineRunning, initialEngine)
        audio.resetStemLevels()
        XCTAssertTrue(audio.stemLevels.values.allSatisfy { $0 == 1 })
        XCTAssertEqual(audio.scheduleGeneration, generation)
    }


    @MainActor
    func testStage38AlbumMatchOrdersTracksByID3TrackNumber() {
        var anchor = Track(id: "a2", title: "Björk - Second", thumbnailURL: nil)
        anchor.cleanArtist = "Björk"; anchor.album = "Vespertine"; anchor.trackNumber = 2
        var first = Track(id: "a1", title: "Björk - First", thumbnailURL: nil)
        first.cleanArtist = "Bjork"; first.album = "VESPERTÍNE"; first.trackNumber = 1
        var third = Track(id: "a3", title: "Björk - Third", thumbnailURL: nil)
        third.cleanArtist = "Björk"; third.album = "Vespertine"; third.trackNumber = 3
        let result = AlbumArtistCollectionResolver.resolve(
            anchor: anchor, candidates: [third, first, anchor], mode: .album)
        XCTAssertEqual(result.albumTracks.map(\.id), ["a1", "a2", "a3"])
        XCTAssertTrue(result.artistTracks.isEmpty)
        XCTAssertFalse(result.usedArtistFallback)
        XCTAssertNil(result.fallbackNotice)
    }

    @MainActor
    func testStage38MissingOrSingleAlbumFallsBackToParsedArtist() {
        var anchor = Track(id: "song1", title: "Rosalía - Saoko", thumbnailURL: nil)
        anchor.album = "Unknown Album"
        let sibling = Track(id: "song2", title: "ROSALIA - Bizcochito", thumbnailURL: nil)
        let noAlbum = AlbumArtistCollectionResolver.resolve(
            anchor: anchor, candidates: [sibling], mode: .album)
        XCTAssertNil(noAlbum.albumTitle)
        XCTAssertEqual(noAlbum.artistName, "Rosalía")
        XCTAssertEqual(noAlbum.artistTracks.map(\.id), ["song1", "song2"])
        XCTAssertTrue(noAlbum.usedArtistFallback)
        XCTAssertNotNil(noAlbum.fallbackNotice)
        anchor.album = "MOTOMAMI"
        let onlyOne = AlbumArtistCollectionResolver.resolve(
            anchor: anchor, candidates: [sibling], mode: .album)
        XCTAssertTrue(onlyOne.usedArtistFallback)
        XCTAssertTrue(onlyOne.albumTracks.isEmpty)
        XCTAssertEqual(onlyOne.playbackTracks.count, 2)
        XCTAssertNil(AlbumArtistCollectionResolver.normalize(" Single "))
    }

    @MainActor
    func testStage38BothDeduplicatesAndQueueCommitsCollectionOnce() {
        var one = Track(id: "one", title: "Aurora - One", thumbnailURL: nil)
        one.album = "A Different Kind of Human"; one.trackNumber = 1
        var two = Track(id: "two", title: "Aurora - Two", thumbnailURL: nil)
        two.album = "A Different Kind of Human"; two.trackNumber = 2
        let other = Track(id: "three", title: "AURORA - Three", thumbnailURL: nil)
        let both = AlbumArtistCollectionResolver.resolve(
            anchor: two, candidates: [one, two, other, other], mode: .both)
        XCTAssertEqual(both.albumTracks.map(\.id), ["one", "two"])
        XCTAssertEqual(both.artistTracks.map(\.id), ["three"])
        XCTAssertEqual(Set(both.playbackTracks.map(\.id)).count, 3)
        // Same atomic queue pattern as ContentView.playMix and playTrack:
        // queue replacement happens after the first track actually starts.
        let queue = PlaybackQueue()
        let playback = both.playbackTracks
        XCTAssertTrue(queue.tracks.isEmpty)
        queue.replace(with: Array(playback.dropFirst()), excluding: playback[0].id)
        XCTAssertEqual(queue.tracks.map(\.id), ["two", "three"])
        XCTAssertTrue(queue.commitPlaying(two))
        XCTAssertEqual(queue.tracks.map(\.id), ["three"])
    }

    func testStage38DrawerUsesExistingOfflineAndTransportWithoutNewEngine() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("NightcoreLab/Sources")
        let panel = try String(contentsOf: root.appendingPathComponent("PanelSystem.swift"), encoding: .utf8)
        let search = try String(contentsOf: root.appendingPathComponent("SearchView.swift"), encoding: .utf8)
        let content = try String(contentsOf: root.appendingPathComponent("ContentView.swift"), encoding: .utf8)
        XCTAssertTrue(panel.contains("case mix, offline, queue, albumArtist"))
        XCTAssertTrue(search.contains("💿 Álbum & Artista"))
        XCTAssertTrue(search.contains("searchDrawer.albumArtistMode"))
        XCTAssertTrue(search.contains("onPlayMix(result.playbackTracks)"))
        XCTAssertTrue(search.contains("onSaveMixOffline(result.playbackTracks)"))
        XCTAssertTrue(search.contains("searchDrawer.focusAlbum."))
        XCTAssertTrue(content.contains("activeTrack: currentTrack"))
        XCTAssertTrue(content.contains("v43 · "))
    }

}
