import XCTest
@testable import NightcoreLab

final class DiscoveryEngineTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func track(_ id: String, artist: String) -> Track {
        Track(id: id, title: "Song " + id, thumbnailURL: nil, cleanArtist: artist)
    }

    private func entry(_ track: Track) -> HistoryEntry {
        HistoryEntry(hit: TrackHit(id: track.id, title: track.title,
            artist: track.cleanArtist ?? "", album: nil, duration: 180, thumb: nil,
            isSong: true, explicit: false), plays: 1, lastPlayed: now,
            completions: 0, earlySkips: 0)
    }

    private func event(_ id: String, material: String,
                       ratio: Double = 0.9,
                       skip: DiscoveryEvent.SkipReason? = nil) -> DiscoveryEvent {
        DiscoveryEvent(trackID: id, timestamp: now, playDuration: 160,
            completionRatio: ratio, skipReason: skip, selectedPreset: "chrome-experience",
            materialID: material, experienceID: "chrome-experience",
            speed: 1.25, audioPreset: "nightcore")
    }

    func testUnknownCapabilitiesRemainMissing() {
        let unknown = DiscoveryFeatureVector()
        let known = DiscoveryFeatureVector(bpm: 140, energy: 0.6)
        XCTAssertNil(unknown.similarity(to: known))
        XCTAssertNil(known.similarity(to: unknown))
    }

    func testBPMOctaveInvarianceAndDeterminism() {
        let a = DiscoveryFeatureVector(bpm: 87, energy: 0.4, rhythmDensity: 0.5)
        let b = DiscoveryFeatureVector(bpm: 174, energy: 0.4, rhythmDensity: 0.5)
        let different = DiscoveryFeatureVector(bpm: 120, energy: 0.9, rhythmDensity: 0.1)
        XCTAssertEqual(try XCTUnwrap(a.similarity(to: b)), 1, accuracy: 0.00001)
        XCTAssertGreaterThan(try XCTUnwrap(a.similarity(to: b)),
                             try XCTUnwrap(a.similarity(to: different)))
    }

    func testColdStartPreservesMixWithNewDiscoverySnapshot() {
        let mix = (0..<8).map { track("mix\($0)", artist: "Same") }
        let context = RecContext(speed: 1.25, now: now)
        let discovery = DiscoverySnapshot(events: [], vectors: [
            "mix0": DiscoveryFeatureVector(bpm: 80),
            "mix5": DiscoveryFeatureVector(bpm: 160)
        ], currentID: "playing", materialID: "chrome", presetID: "x")
        let result = RecommendationRanker.recommendations(mix: mix, history: [:],
            currentID: "playing", queued: [], context: context, discovery: discovery)
        XCTAssertEqual(result.map(\.id), mix.map(\.id))
    }

    func testAcousticSimilarityIncreasesScoreOnlyWithTwoVectors() {
        let song = track("candidate", artist: "Future")
        let candidate = RecCandidate(track: song, mixIndex: 0)
        let profile = UserTasteProfile(history: ["history": entry(track("history", artist: "Old"))])
        let context = RecContext(speed: 1, now: now)
        let baseline = RecommendationRanker.score(candidate, profile: profile, context: context)
        let partial = DiscoverySnapshot(events: [], vectors: [
            "candidate": DiscoveryFeatureVector(bpm: 100, energy: 0.2)
        ], currentID: "playing", materialID: nil, presetID: nil)
        XCTAssertEqual(RecommendationRanker.score(candidate, profile: profile,
                                                   context: context, discovery: partial), baseline)
        let complete = DiscoverySnapshot(events: [], vectors: [
            "candidate": DiscoveryFeatureVector(bpm: 100, energy: 0.2),
            "playing": DiscoveryFeatureVector(bpm: 200, energy: 0.2)
        ], currentID: "playing", materialID: nil, presetID: nil)
        XCTAssertGreaterThan(RecommendationRanker.score(candidate, profile: profile,
            context: context, discovery: complete), baseline)
        XCTAssertNotNil(RecommendationRanker.whyAppeared(song, history: profile.history,
            context: context, discovery: complete))
    }

    func testCreativeMaterialAndSpeedInfluenceRankingAndExplanation() {
        let original = track("old", artist: "ArtistOne")
        let suggested = track("new", artist: "ArtistOne")
        let profile = UserTasteProfile(history: ["old": entry(original)])
        let candidate = RecCandidate(track: suggested, mixIndex: 0)
        let context = RecContext(speed: 1.25, now: now)
        func snapshot(_ material: String, _ speed: Float = 1.25) -> (DiscoverySnapshot, RecContext) {
            (DiscoverySnapshot(events: [event("old", material: "chrome")],
                vectors: [:], currentID: "old", materialID: material,
                presetID: "chrome-experience"), RecContext(speed: speed, now: now))
        }
        let (matching, fast) = snapshot("chrome")
        let (otherMaterial, _) = snapshot("marble")
        let (wrongSpeed, slow) = snapshot("chrome", 0.8)
        let matchingScore = RecommendationRanker.score(candidate, profile: profile,
            context: fast, discovery: matching)
        XCTAssertGreaterThan(matchingScore, RecommendationRanker.score(candidate,
            profile: profile, context: fast, discovery: otherMaterial))
        XCTAssertGreaterThan(matchingScore, RecommendationRanker.score(candidate,
            profile: profile, context: slow, discovery: wrongSpeed))
        XCTAssertTrue((RecommendationRanker.whyAppeared(suggested, history: profile.history,
            context: fast, discovery: matching) ?? "").contains("1.25x + chrome"))
    }

    func testManualEarlySkipPenalizesCandidateNotAnUnplayedTrack() {
        let current = track("old", artist: "ArtistOne")
        let suggestion = RecCandidate(track: track("next", artist: "ArtistOne"), mixIndex: 0)
        let profile = UserTasteProfile(history: ["old": entry(current)])
        let context = RecContext(speed: 1, now: now)
        let baseline = RecommendationRanker.score(suggestion, profile: profile, context: context)
        let skipped = DiscoveryEvent(trackID: "old", playDuration: 3,
            completionRatio: 0.02, skipReason: .manualSelection)
        let discovery = DiscoverySnapshot(events: [skipped], vectors: [:],
            currentID: "old", materialID: nil, presetID: nil)
        XCTAssertLessThan(RecommendationRanker.score(suggestion, profile: profile,
            context: context, discovery: discovery), baseline)
    }

    @MainActor
    func testTrackerUsesMonotonicListenTimeAcrossPauseSeekAndSpeedChange() throws {
        let tracker = DiscoveryPlaybackTracker()
        tracker.start("test", duration: 200, speed: 1.25, uptime: 100)
        tracker.playbackChanged(isPlaying: false, speed: 1.25, uptime: 120)
        // Seek while paused does not change exposure.
        tracker.playbackChanged(isPlaying: true, speed: 1.25, uptime: 200)
        tracker.contextChanged(speed: 1, uptime: 220)
        let result = try XCTUnwrap(tracker.finish(reason: .manualSelection, selectedPreset: "x",
            materialID: "chrome", experienceID: "x", audioPreset: "nightcore",
            uptime: 230, at: now))
        XCTAssertEqual(result.playDuration, 50, accuracy: 0.001)
        XCTAssertEqual(result.completionRatio, 60 / 200, accuracy: 0.001)
        XCTAssertEqual(result.skipReason, .manualSelection)
        XCTAssertNil(tracker.finish(reason: .stopped, selectedPreset: nil,
            materialID: nil, experienceID: nil, audioPreset: nil, uptime: 231))
    }

    @MainActor
    func testExportIsRecordedOnlyOnSuccessWithoutEndingPlayback() throws {
        let tracker = DiscoveryPlaybackTracker()
        tracker.start("a", duration: 40, speed: 1, uptime: 0)
        let exported = try XCTUnwrap(tracker.finish(reason: nil, selectedPreset: nil,
            materialID: nil, experienceID: nil, audioPreset: nil,
            exported: true, uptime: 10))
        XCTAssertTrue(exported.exported)
        let finished = try XCTUnwrap(tracker.finish(reason: .completed, selectedPreset: nil,
            materialID: nil, experienceID: nil, audioPreset: nil, uptime: 20))
        XCTAssertFalse(finished.exported)
        XCTAssertEqual(finished.playDuration, 20)
        XCTAssertEqual(finished.completionRatio, 1)
    }

    func testQueueReordersAfterSkipButKeepsExistingTracks() {
        let anchor = track("anchor", artist: "A")
        let far = track("far", artist: "A")
        let close = track("close", artist: "B")
        let vectors = [
            "anchor": DiscoveryFeatureVector(bpm: 100, energy: 0.1),
            "far": DiscoveryFeatureVector(bpm: 144, energy: 0.9),
            "close": DiscoveryFeatureVector(bpm: 200, energy: 0.1)
        ]
        let output = DiscoveryQueuePolicy.afterSkip([far, close], anchor: anchor,
            vectors: vectors)
        XCTAssertEqual(output.map(\.id), ["close", "far"])
        XCTAssertEqual(Set(output.map(\.id)), Set([far.id, close.id]))
        XCTAssertEqual(DiscoveryQueuePolicy.afterSkip([far, close], anchor: anchor,
            vectors: [:]).map(\.id), ["far", "close"])
    }

    func testLowPowerEnergyBudgetDisallowsAnalysis() {
        var budget = EnergyBudget()
        budget.lowPower = true
        XCTAssertFalse(budget.allowsNewAnalysis)
        budget.lowPower = false
        budget.thermal = .serious
        XCTAssertFalse(budget.allowsNewAnalysis)
    }

    func testEventSanitization() {
        let event = DiscoveryEvent(trackID: "a", playDuration: .nan,
            completionRatio: 10, speed: -.infinity)
        XCTAssertEqual(event.playDuration, 0)
        XCTAssertEqual(event.completionRatio, 1)
        XCTAssertNil(event.speed)
    }

    func testLogPersistsLocallyReloadsAndClears() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("DiscoveryTest-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let log = DiscoveryEventLog(directory: directory)
        await log.append(event("a", material: "chrome"))
        await log.append(event("b", material: "marble"))
        let restored = DiscoveryEventLog(directory: directory)
        let items = await restored.snapshot()
        XCTAssertEqual(items.map(\.trackID), ["a", "b"])
        await restored.clear()
        let empty = await DiscoveryEventLog(directory: directory).snapshot()
        XCTAssertTrue(empty.isEmpty)
    }
}
