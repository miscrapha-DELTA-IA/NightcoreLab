import XCTest
@testable import NightcoreLab

final class NowPlayingScreenTests: XCTestCase {
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
