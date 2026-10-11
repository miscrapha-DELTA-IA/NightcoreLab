import Foundation
import XCTest
@testable import NightcoreLab

final class OmniboxAndLyricsPipelineTests: XCTestCase {
    func testDirectYouTubeURLAndVideoID() {
        XCTAssertEqual(OmniboxIntent.classify("https://youtu.be/dQw4w9WgXcQ"),
                       .direct(videoID: "dQw4w9WgXcQ"))
        XCTAssertEqual(OmniboxIntent.classify("dQw4w9WgXcQ"),
                       .direct(videoID: "dQw4w9WgXcQ"))
        XCTAssertEqual(OmniboxIntent.classify("mockingbird"), .text("mockingbird"))
    }

    func testMetadataCleanerStripsYouTubeNoiseAndKeepsArtist() {
        let cleaned = MetadataCleaner.clean(rawTitle: "Artist - Track (Official Music Video)",
                                            channel: "Uploader Hub")
        XCTAssertEqual(cleaned.title, "Track")
        XCTAssertEqual(cleaned.artist, "Artist")
        XCTAssertTrue(cleaned.artistIsReliable)
    }

    func testRankingSkipsUnsyncedLyricsAndRejectsWrongTitle() {
        let metadata = TrackMetadata(videoID: "dQw4w9WgXcQ", rawTitle: "Artist - Track",
                                     channel: nil, cleanArtist: "Artist", cleanTitle: "Track",
                                     album: nil, duration: 180)
        let query = LyricsQuery(metadata)
        let staticRecord = LRCLIBRecord(id: 1, trackName: "Track", artistName: "Artist",
                                       albumName: nil, duration: 180, instrumental: false,
                                       plainLyrics: "Words", syncedLyrics: nil)
        let timed = LRCLIBRecord(id: 2, trackName: "Track", artistName: "Artist",
                                albumName: nil, duration: 180, instrumental: false,
                                plainLyrics: "Words", syncedLyrics: "[00:01.00]Words")
        let wrong = LRCLIBRecord(id: 3, trackName: "Completely Different", artistName: "Someone",
                                albumName: nil, duration: 400, instrumental: false,
                                plainLyrics: nil, syncedLyrics: "[00:01.00]Other")
        let ranked = RankedLyricsMatcher.rank(query, [staticRecord, timed, wrong])
        XCTAssertFalse(ranked.contains { $0.record.id == 1 })
        XCTAssertEqual(ranked.first?.record.id, 2)
        XCTAssertEqual(ranked.first?.verdict, .confident)
        XCTAssertTrue(ranked.contains { $0.record.id == 3 && $0.verdict == .rejected })
    }

    func testStructuredSongToTrackCarriesMetadata() {
        let hit = TrackHit(id: "dQw4w9WgXcQ", title: "Track", artist: "Artist",
                           album: "Album", duration: 180,
                           thumb: URL(string: "https://example.org/cover.jpg"),
                           isSong: true, explicit: false)
        let mapped = hit.asTrack
        XCTAssertEqual(mapped.cleanArtist, "Artist")
        XCTAssertEqual(mapped.cleanTitle, "Track")
        XCTAssertEqual(mapped.album, "Album")
        XCTAssertEqual(mapped.duration, 180)
    }
}
