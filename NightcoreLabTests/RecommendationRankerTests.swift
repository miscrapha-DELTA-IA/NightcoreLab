import XCTest
@testable import NightcoreLab

final class RecommendationRankerTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private func track(_ id: String, artist: String = "Artist", title: String? = nil,
                       duration: TimeInterval? = nil) -> Track {
        Track(id: id, title: title ?? id, thumbnailURL: nil,
              cleanArtist: artist.isEmpty ? nil : artist, duration: duration)
    }
    private func entry(_ id: String, artist: String = "Artist", plays: Int = 3,
                       completions: Int = 2, age: TimeInterval = 0) -> HistoryEntry {
        HistoryEntry(hit: TrackHit(id: id, title: id, artist: artist, album: nil,
            duration: nil, thumb: nil, isSong: true, explicit: false),
            plays: plays, lastPlayed: now.addingTimeInterval(-age), completions: completions)
    }
    private func context(_ speed: Float = 1) -> RecContext { RecContext(speed: speed, now: now) }

    func testColdStartPreservesMixOrderEvenWithSameArtistAndFastSpeed() {
        let mix = (0..<10).map { track("m\($0)") }
        XCTAssertEqual(RecommendationRanker.recommendations(mix: mix, history: [:], currentID: "playing",
            queued: [], context: context(1.25)).map(\.id), mix.map(\.id))
    }

    func testCompletedArtistRanksAboveUnknownAtSameMixPosition() {
        let profile = UserTasteProfile(history: ["old": entry("old")])
        let known = RecCandidate(track: track("known"), mixIndex: 0)
        let unknown = RecCandidate(track: track("unknown", artist: "Other"), mixIndex: 0)
        XCTAssertEqual(RecommendationRanker.rank([unknown, known], profile: profile,
            context: context()).first?.track.id, "known")
    }

    func testRecentSkipDemotesSameTrackAndArtistWithDecay() {
        var skipped = entry("old", plays: 1, completions: 0)
        skipped.earlySkips = 1
        skipped.lastSkippedAt = now
        let profile = UserTasteProfile(history: ["old": skipped])
        let known = RecCandidate(track: track("same-artist"), mixIndex: 0)
        let unknown = RecCandidate(track: track("other", artist: "Other"), mixIndex: 0)
        XCTAssertEqual(RecommendationRanker.rank([known, unknown], profile: profile,
            context: context()).first?.track.id, "other")
        XCTAssertGreaterThan(RecommendationRanker.skipPenalty(skipped, now: now),
            RecommendationRanker.skipPenalty(skipped, now: now.addingTimeInterval(21 * 86_400)))
        XCTAssertGreaterThan(RecommendationRanker.skipPenalty(skipped, now: now.addingTimeInterval(21 * 86_400)),
            RecommendationRanker.skipPenalty(skipped, now: now.addingTimeInterval(84 * 86_400)))
    }

    func testPlaybackSpeedFavorsMatchingVersion() {
        let fast = RecCandidate(track: track("fast", title: "Song (Sped Up)"), mixIndex: 0)
        let slow = RecCandidate(track: track("slow", title: "Song (Slowed)"), mixIndex: 0)
        let profile = UserTasteProfile(history: [:])
        XCTAssertEqual(RecommendationRanker.rank([slow, fast], profile: profile, context: context(1.25)).first?.track.id, "fast")
        XCTAssertEqual(RecommendationRanker.rank([fast, slow], profile: profile, context: context(0.8)).first?.track.id, "slow")
    }

    func testUnknownDurationIsNeutralAndLiveAllowsLongDuration() {
        let profile = UserTasteProfile(history: [:])
        func score(_ duration: TimeInterval?, title: String = "Song") -> Double {
            RecommendationRanker.score(RecCandidate(track: track("a", title: title, duration: duration), mixIndex: 0),
                                       profile: profile, context: context())
        }
        XCTAssertEqual(score(nil), score(180))
        XCTAssertLessThan(score(1000), score(180))
        XCTAssertEqual(score(1000, title: "Song (Live)"), score(180))
    }

    func testSourceQuotaAndNoMoreThanTwoPerArtist() {
        let familiar = (0..<10).map { RecCandidate(track: track("h\($0)", artist: "H\($0 / 2)"), mixIndex: nil) }
        let mix = (0..<10).map { RecCandidate(track: track("m\($0)", artist: "M\($0 / 2)"), mixIndex: $0) }
        for (events, count) in [(0, 0), (15, 4), (30, 7), (90, 7)] {
            let share = RecommendationRanker.familiarShare(eventCount: events)
            let result = RecommendationRanker.diversify(familiar + mix, familiarShare: share)
            XCTAssertEqual(result.count, 10)
            XCTAssertEqual(result.filter { $0.id.hasPrefix("h") }.count, count)
            for index in 2..<result.count {
                let group = result[(index - 2)...index].map { $0.cleanArtist }
                XCTAssertFalse(group[0] == group[1] && group[1] == group[2])
            }
        }
    }

    func testDiversificationHonorsExistingQueueTailAndUnknownArtists() {
        let candidates = [RecCandidate(track: track("a"), mixIndex: 0),
                          RecCandidate(track: track("b", artist: "Other"), mixIndex: 1)]
        let result = RecommendationRanker.diversify(candidates, familiarShare: 0,
                                                   precedingArtists: ["artist", "artist"])
        XCTAssertEqual(result.first?.id, "b")
        let unknown = (0..<10).map { RecCandidate(track: track("u\($0)", artist: ""), mixIndex: $0) }
        XCTAssertEqual(RecommendationRanker.diversify(unknown, familiarShare: 0).count, 10)
    }

    func testInsufficientDiversityReturnsShorterBatchInsteadOfThreeInARow() {
        let same = (0..<10).map { RecCandidate(track: track("s\($0)"), mixIndex: $0) }
        XCTAssertEqual(RecommendationRanker.diversify(same, familiarShare: 0).count, 2)
    }

    func testNoEligibleHistoryFallsBackToMixAndEmptyMixNeverUsesHistoryAlone() {
        let history = ["h": entry("h")]
        let mix = (0..<10).map { track("m\($0)", artist: "M\($0)") }
        XCTAssertEqual(RecommendationRanker.recommendations(mix: mix, history: history, currentID: "playing",
            queued: [], context: context()).count, 10)
        XCTAssertTrue(RecommendationRanker.recommendations(mix: [], history: history, currentID: "playing",
            queued: [], context: context()).isEmpty)
    }

    func testExcludesCurrentQueuedDuplicatesRecentAndSkippedHistory() {
        var history: [String: HistoryEntry] = [:]
        for i in 0..<10 { history["recent\(i)"] = entry("recent\(i)", age: Double(i)) }
        history["old"] = entry("old", artist: "Older", age: 1000)
        var skipped = entry("skipped", age: 1000)
        skipped.earlySkips = 1; skipped.lastSkippedAt = now
        history["skipped"] = skipped
        let mix = [track("playing"), track("queued"), track("new", artist: "New"), track("new", artist: "New")]
        let result = RecommendationRanker.recommendations(mix: mix, history: history, currentID: "playing",
            queued: [track("queued")], context: context()).map(\.id)
        XCTAssertEqual(Set(result), ["old", "new"])
        XCTAssertEqual(result.count, Set(result).count)
    }

    func testDeterministicTieBreaks() {
        let items = [RecCandidate(track: track("b"), mixIndex: nil), RecCandidate(track: track("a"), mixIndex: nil)]
        let profile = UserTasteProfile(history: [:])
        XCTAssertEqual(RecommendationRanker.rank(items, profile: profile, context: context()).map { $0.track.id }, ["a", "b"])
    }
}

final class TrackFeaturesTests: XCTestCase {
    func testMixTitleProvidesArtistAndVersionWithoutInventingDuration() {
        let features = TrackFeatures(track: Track(id: "a", title: "Artist - Song (Sped Up)", thumbnailURL: nil))
        XCTAssertEqual(features.primaryArtist, "artist")
        XCTAssertTrue(features.artistIsReliable)
        XCTAssertTrue(features.versionTags.contains(.spedUp))
        XCTAssertNil(features.duration)
    }
    func testUploaderIsUnreliableAndMissingArtistStaysMissing() {
        let upload = TrackFeatures(rawTitle: "Song (Slowed)", channel: "Uploader Hub")
        XCTAssertFalse(upload.artistIsReliable)
        XCTAssertTrue(upload.versionTags.contains(.slowed))
        let unknown = TrackFeatures(rawTitle: "Song", channel: nil)
        XCTAssertTrue(unknown.artists.isEmpty)
        XCTAssertNil(unknown.primaryArtist)
    }
    func testStructuredAndTopicArtistsAreReliableAndSplitCollaborations() {
        let features = TrackFeatures(rawTitle: "Song (Live)", channel: nil, structuredArtist: "Alice & Bob")
        XCTAssertEqual(features.artists, ["alice", "bob"])
        XCTAssertTrue(features.artistIsReliable)
        XCTAssertTrue(features.allowsLongDuration)
        XCTAssertTrue(TrackFeatures(rawTitle: "Song", channel: "Alice - Topic").artistIsReliable)
    }
}
