import XCTest
@testable import NightcoreLab

final class LyricsMatchingTests: XCTestCase {
    private func record(_ id: Int, title: String, artist: String, duration: Double,
                        synced: String? = "[00:01.00] Test") -> LyricsRecord {
        LyricsRecord(id: id, trackName: title, artistName: artist,
                     duration: duration, syncedLyrics: synced,
                     plainLyrics: nil, instrumental: false)
    }

    func testFirstSyncedSearchHitCannotOverrideTheCorrectSong() throws {
        let wrong = record(1, title: "Hello", artist: "Adele", duration: 295)
        let correct = record(2, title: "Yellow", artist: "Coldplay", duration: 266)
        let chosen = LyricsMatcher.best([wrong, correct],
                                        youtubeTitle: "Coldplay - Yellow (Official Video)",
                                        audioDuration: 266)
        XCTAssertEqual(chosen?.id, 2)
    }

    func testWrongArtistWithSameTitleIsNotTrusted() {
        let other = record(1, title: "Hello", artist: "Lionel Richie", duration: 295)
        XCTAssertNil(LyricsMatcher.best([other], youtubeTitle: "Adele - Hello",
                                        audioDuration: 295))
    }

    func testLargeDurationMismatchRejectsLiveAndCoverVersions() {
        let wrong = record(1, title: "Yellow", artist: "Coldplay", duration: 320)
        XCTAssertNil(LyricsMatcher.best([wrong],
                                        youtubeTitle: "Coldplay - Yellow (Live)",
                                        audioDuration: 266))
    }

    func testUnknownArtistNeedsExactNameAndVeryCloseDuration() {
        let close = record(1, title: "Yellow", artist: "Coldplay", duration: 266)
        XCTAssertEqual(LyricsMatcher.best([close], youtubeTitle: "Yellow",
                                          audioDuration: 265)?.id, 1)
        XCTAssertNil(LyricsMatcher.best([close], youtubeTitle: "Yellow",
                                        audioDuration: 257))
    }

    func testAmbiguousTitleAcrossArtistsRequiresManualSelection() {
        let one = record(1, title: "Hello", artist: "Adele", duration: 295)
        let two = record(2, title: "Hello", artist: "Lionel Richie", duration: 295)
        XCTAssertNil(LyricsMatcher.best([one, two], youtubeTitle: "Hello",
                                        audioDuration: 295))
    }

    func testSyncedLyricsWinOverVerifiedPlainLyrics() {
        let plain = LyricsRecord(id: 1, trackName: "Yellow", artistName: "Coldplay",
                                 duration: 266, syncedLyrics: nil, plainLyrics: "Hello",
                                 instrumental: false)
        let synchronized = record(2, title: "Yellow", artist: "Coldplay",
                                  duration: 267)
        XCTAssertEqual(LyricsMatcher.best([plain, synchronized],
                                          youtubeTitle: "Coldplay - Yellow",
                                          audioDuration: 266)?.id, 2)
    }

    func testBareYouTubeIDDoesNotTriggerWrongLyrics() {
        XCTAssertNil(LyricsMatcher.identity(from: "abcdefghijk"))
        XCTAssertNil(LyricsMatcher.best([record(1, title: "Hello", artist: "Adele",
                                                duration: 295)],
                                        youtubeTitle: "abcdefghijk", audioDuration: 295))
    }

    func testRemovesPresentationTagsWithoutDroppingTrackTitle() {
        let identity = LyricsMatcher.identity(
            from: "Coldplay - Yellow (Official Music Video) [Slowed + Reverb]")
        XCTAssertEqual(identity?.artist, "Coldplay")
        XCTAssertEqual(identity?.title, "Yellow")
    }

    func testAccentAndUnicodeNormalization() {
        XCTAssertEqual(LyricsMatcher.normalized("Beyoncé – Déjà Vu"), "beyonce deja vu")
        XCTAssertEqual(LyricsMatcher.similarity("Beyoncé", "Beyonce"), 1)
    }

    func testInvalidLyricsNeverAutoSelected() {
        var instrumental = record(1, title: "Yellow", artist: "Coldplay", duration: 266,
                                  synced: nil)
        instrumental = LyricsRecord(id: instrumental.id, trackName: instrumental.trackName,
                                   artistName: instrumental.artistName, duration: instrumental.duration,
                                   syncedLyrics: nil, plainLyrics: nil, instrumental: true)
        XCTAssertNil(LyricsMatcher.best([instrumental],
                                        youtubeTitle: "Coldplay - Yellow", audioDuration: 266))
    }

    func testSortedCandidatesPreferTheActualSongRegardlessOfApiOrder() {
        let other = record(1, title: "Yellow Brick Road", artist: "Elton John", duration: 266)
        let correct = record(2, title: "Yellow", artist: "Coldplay", duration: 266)
        let sorted = LyricsMatcher.sorted([other, correct],
                                          for: LyricsMatcher.identity(from: "Coldplay - Yellow"),
                                          audioDuration: 266)
        XCTAssertEqual(sorted.first?.id, 2)
    }
}
