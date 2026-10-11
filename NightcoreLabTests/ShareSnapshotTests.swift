import XCTest
import SwiftUI
import UIKit
@testable import NightcoreLab

final class ShareSnapshotTests: XCTestCase {
    @MainActor
    func testSnapshotCapturesTrackAndDoesNotChangeWhenInputChanges() {
        let url = URL(string: "https://example.org/cover.png")
        let track = Track(id: "12345678901", title: "Title 🎵 / 特殊", thumbnailURL: url,
                          cleanArtist: "Artist & Friends")
        let info = TrackInfo(track: track, fileName: nil, coverURL: nil)
        let start = Date(timeIntervalSince1970: 1_000)
        let capture = start.addingTimeInterval(10)
        let snapshot = ShareSnapshotBuilder.make(track: info, theme: .ultrapink,
            visualStyle: .marble, marbleStartedAt: start, speed: 0.6, capturedAt: capture)
        XCTAssertEqual(snapshot.trackID, track.id)
        XCTAssertEqual(snapshot.title, "Title 🎵 / 特殊")
        XCTAssertEqual(snapshot.artist, "Artist & Friends")
        XCTAssertEqual(snapshot.artworkURL, url)
        XCTAssertEqual(snapshot.theme, .ultrapink)
        XCTAssertEqual(snapshot.marblePhase, 6, accuracy: 0.001)
        XCTAssertEqual(snapshot.timestamp, capture)
    }

    @MainActor
    func testLocalFileWithoutArtworkIsAllowed() {
        let info = TrackInfo(track: nil, fileName: "demo.m4a", coverURL: nil)
        let value = ShareSnapshotBuilder.make(track: info, theme: .ultrablack,
            visualStyle: .blurredArtwork, marbleStartedAt: .now, speed: 0.6)
        XCTAssertEqual(value.title, "demo.m4a")
        XCTAssertEqual(value.artist, "Arquivo local")
        XCTAssertNil(value.artworkURL)
    }

    func testBlankArtistAndTitleHaveStableFallbacks() {
        let value = ShareSnapshot(trackID: "a", title: "   ", artist: "  ",
            artworkURL: nil, theme: .purewhite, visualStyle: .marble,
            marblePhase: -1, timestamp: .now)
        XCTAssertEqual(value.title, "Música sem título")
        XCTAssertNil(value.artist)
        XCTAssertEqual(value.marblePhase, 0)
    }

    @MainActor
    func testEveryCurrentThemeCanBeCaptured() {
        XCTAssertEqual(AppTheme.allCases.count, 17)
        for theme in AppTheme.allCases {
            let value = ShareSnapshot(trackID: "a", title: "Long Title", artist: "Artist",
                artworkURL: nil, theme: theme, visualStyle: .marble,
                marblePhase: 2.5, timestamp: .now)
            XCTAssertEqual(MarbleTheme(appTheme: value.theme).rawValue, theme.rawValue)
        }
    }

    @MainActor
    func testImageRendererProducesPortraitCardWithoutNetwork() async throws {
        let sample = ShareSnapshot(trackID: "a", title: "NightcoreLab",
            artist: "Artista", artworkURL: nil, theme: .purewhite,
            visualStyle: .marble, marblePhase: 0, timestamp: .now)
        let image = try await ShareRenderer.render(sample)
        XCTAssertEqual(image.size.width * image.scale, 1080, accuracy: 1)
        XCTAssertEqual(image.size.height * image.scale, 1920, accuracy: 1)
    }
}
