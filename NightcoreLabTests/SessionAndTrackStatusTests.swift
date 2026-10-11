import XCTest
@testable import NightcoreLab

final class SessionAndTrackStatusTests: XCTestCase {
    private func defaults() -> UserDefaults {
        let suite = "nightcore.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return defaults
    }

    private func track() -> Track {
        Track(id: "abcdefghijk", title: "Artist - Track",
              thumbnailURL: URL(string: "https://i.ytimg.com/vi/abcdefghijk/hqdefault.jpg"))
    }

    func testSessionJSONRoundTripIncludesPosition() throws {
        let storage = defaults()
        PlaybackSessionStorage.save(track(), at: 42.25, defaults: storage)
        let restored = try XCTUnwrap(PlaybackSessionStorage.load(defaults: storage))
        XCTAssertEqual(restored.track.id, "abcdefghijk")
        XCTAssertEqual(restored.track.title, "Artist - Track")
        XCTAssertEqual(restored.position, 42.25, accuracy: 0.001)
    }

    func testSessionCanBeClearedAndCorruptionIsIgnored() {
        let storage = defaults()
        PlaybackSessionStorage.save(track(), at: 10, defaults: storage)
        PlaybackSessionStorage.clear(defaults: storage)
        XCTAssertNil(PlaybackSessionStorage.load(defaults: storage))
        storage.set(Data("invalid-json".utf8), forKey: PlaybackSessionStorage.key)
        XCTAssertNil(PlaybackSessionStorage.load(defaults: storage))
    }

    func testNonFinitePlaybackTimeIsSanitized() throws {
        let storage = defaults()
        PlaybackSessionStorage.save(track(), at: .infinity, defaults: storage)
        XCTAssertEqual(PlaybackSessionStorage.load(defaults: storage)?.position, 0)
        PlaybackSessionStorage.save(track(), at: -10, defaults: storage)
        XCTAssertEqual(PlaybackSessionStorage.load(defaults: storage)?.position, 0)
    }

    func testVisualTrackStatesRespectCacheFirst() {
        XCTAssertEqual(TrackStatus.resolve(cached: false, downloading: false), .none)
        XCTAssertEqual(TrackStatus.resolve(cached: false, downloading: true), .downloading)
        XCTAssertEqual(TrackStatus.resolve(cached: true, downloading: false), .downloaded)
        XCTAssertEqual(TrackStatus.resolve(cached: true, downloading: true), .downloaded)
    }

    func testTrackStatusCodable() throws {
        for status in [TrackStatus.none, .downloading, .downloaded] {
            let bytes = try JSONEncoder().encode(status)
            XCTAssertEqual(try JSONDecoder().decode(TrackStatus.self, from: bytes), status)
        }
    }
}
