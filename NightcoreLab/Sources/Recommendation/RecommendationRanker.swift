import Foundation

struct RecCandidate {
    let track: Track
    let features: TrackFeatures
    let mixIndex: Int?
    var isFamiliar: Bool { mixIndex == nil }

    init(track: Track, mixIndex: Int?) {
        self.track = track
        self.features = TrackFeatures(track: track)
        self.mixIndex = mixIndex
    }
}

struct RecContext {
    let speed: Float
    let now: Date
}

enum RecommendationRanker {
    enum Policy {
        static let batchSize = 10
        static let recentTrackCount = 30
        static let maxArtistRun = 2
        static let maxArtistPerBatch = 3
        static let skipDecayDays = 21.0
        static let maxFamiliarShare = 0.3
        static let eventsForFullShare = 30.0
        static let fastSpeed: Float = 1.1
        static let slowSpeed: Float = 0.9
        static let durationRange = 45.0...720.0
    }
    enum Weights {
        static let affinity = 0.30
        static let history = 0.20
        static let mixOrder = 0.25
        static let context = 0.10
        static let novelty = 0.15
        static let skip = 0.30
        static let duration = 0.25
    }

    static func familiarShare(eventCount: Int) -> Double {
        Policy.maxFamiliarShare * min(1, Double(max(0, eventCount)) / Policy.eventsForFullShare)
    }

    /// Different uploads of the same recording must not bypass recent history.
    static func recordingKey(_ track: Track) -> String {
        let features = TrackFeatures(track: track)
        guard features.artistIsReliable, let artist = features.primaryArtist else { return "id:" + track.id }
        let cleaned = MetadataCleaner.clean(rawTitle: track.cleanTitle ?? track.title, channel: nil)
        return artist + "|" + MetadataCleaner.key(cleaned.title)
    }

    static func skipPenalty(_ entry: HistoryEntry, now: Date) -> Double {
        guard let skipped = entry.lastSkippedAt, (entry.earlySkips ?? 0) > 0 else { return 0 }
        let days = max(0, now.timeIntervalSince(skipped) / 86_400)
        let strength = min(1, Double(entry.earlySkips ?? 0) / Double(max(1, entry.plays)))
        return strength * exp(-days / Policy.skipDecayDays)
    }

    static func score(_ candidate: RecCandidate, profile: UserTasteProfile, context: RecContext,
                      discovery: DiscoverySnapshot = .empty) -> Double {
        let features = candidate.features
        let prior = candidate.mixIndex.map { 1 / (1 + 0.35 * Double($0)) } ?? 0
        var audioContext = 0.0
        if context.speed > Policy.fastSpeed {
            audioContext = (features.versionTags.contains(.spedUp) ? 1 : 0)
                - (features.versionTags.contains(.slowed) ? 1 : 0)
        } else if context.speed < Policy.slowSpeed {
            audioContext = (features.versionTags.contains(.slowed) ? 1 : 0)
                - (features.versionTags.contains(.spedUp) ? 1 : 0)
        }
        let entry = profile.history[candidate.track.id]
        var skip = entry.map { skipPenalty($0, now: context.now) } ?? 0
        // Unknown artists never form a shared group or a cross-track penalty.
        for played in profile.history.values where (played.earlySkips ?? 0) > 0 {
            guard let other = profile.featuresByID[played.hit.id] else { continue }
            if !features.artists.isDisjoint(with: other.artists) {
                let confidence = features.artistIsReliable && other.artistIsReliable ? 1.0 : 0.35
                skip = max(skip, confidence * skipPenalty(played, now: context.now))
            }
        }
        let durationPenalty = features.duration.map {
            !Policy.durationRange.contains($0) && !features.allowsLongDuration ? Weights.duration : 0
        } ?? 0
        let discoveryBonus = DiscoveryScoring.contribution(for: candidate, profile: profile,
                                                            context: context, snapshot: discovery).total
        return Weights.affinity * profile.affinity(for: features)
            + Weights.history * OmniboxRanker.frecency(entry, now: context.now)
            + Weights.mixOrder * prior + Weights.context * audioContext
            + (entry == nil ? Weights.novelty : 0)
            - Weights.skip * skip - durationPenalty + discoveryBonus
    }

    static func rank(_ candidates: [RecCandidate], profile: UserTasteProfile,
                     context: RecContext, discovery: DiscoverySnapshot = .empty) -> [RecCandidate] {
        candidates.map { ($0, score($0, profile: profile, context: context,
                                    discovery: discovery)) }
            .sorted {
                if $0.1 != $1.1 { return $0.1 > $1.1 }
                let lhs = $0.0.mixIndex ?? Int.max, rhs = $1.0.mixIndex ?? Int.max
                return lhs == rhs ? $0.0.track.id < $1.0.track.id : lhs < rhs
            }.map { $0.0 }
    }

    /// Quotas count sources: Mix can itself contain songs already heard.
    /// If diversity makes a full batch impossible, prefer a shorter valid batch.
    static func diversify(_ ranked: [RecCandidate], familiarShare: Double,
                          maxRun: Int = Policy.maxArtistRun, limit: Int = Policy.batchSize,
                          precedingArtists: [String?] = []) -> [Track] {
        guard limit > 0, maxRun > 0 else { return [] }
        var seen = Set<String>()
        let unique = ranked.filter { seen.insert(recordingKey($0.track)).inserted }
        var familiar = unique.filter(\.isFamiliar)
        var mix = unique.filter { !$0.isFamiliar }
        let count = min(limit, unique.count)
        let desired = Int((Double(limit) * min(1, max(0, familiarShare))).rounded())
        let familiarTarget = min(familiar.count, max(count - mix.count, min(count, desired)))
        let mixTarget = count - familiarTarget
        var familiarUsed = 0, mixUsed = 0
        var artists = precedingArtists
        var output: [Track] = []
        func allowed(_ candidate: RecCandidate) -> Bool {
            guard let artist = candidate.features.primaryArtist else { return true }
            guard artists.filter({ $0 == artist }).count < Policy.maxArtistPerBatch else { return false }
            let tail = artists.suffix(maxRun)
            return tail.count < maxRun || !tail.allSatisfy { $0 == artist }
        }
        while output.count < count {
            let familiarIndex = familiarUsed < familiarTarget ? familiar.firstIndex(where: allowed) : nil
            let mixIndex = mixUsed < mixTarget ? mix.firstIndex(where: allowed) : nil
            let preferFamiliar = familiarUsed < Int((Double(output.count + 1) * Double(familiarTarget) / Double(max(1, count))).rounded())
            let candidate: RecCandidate
            if let index = familiarIndex, preferFamiliar || mixIndex == nil {
                candidate = familiar.remove(at: index)
                familiarUsed += 1
            } else if let index = mixIndex {
                candidate = mix.remove(at: index)
                mixUsed += 1
            } else {
                break
            }
            output.append(candidate.track)
            artists.append(candidate.features.primaryArtist)
        }
        return output
    }

    static func whyAppeared(_ track: Track, history: [String: HistoryEntry],
                            context: RecContext, discovery: DiscoverySnapshot) -> String? {
        guard !discovery.events.isEmpty || !discovery.vectors.isEmpty else { return nil }
        return DiscoveryScoring.contribution(
            for: RecCandidate(track: track, mixIndex: 0),
            profile: UserTasteProfile(history: history),
            context: context, snapshot: discovery).explanation
    }

    static func recommendations(mix: [Track], history: [String: HistoryEntry],
                                currentID: String, queued: [Track], context: RecContext,
                                discovery: DiscoverySnapshot = .empty,
                                recentlySuggested: Set<String> = []) -> [Track] {
        // Never substitute a history-only radio when /related fails or is empty.
        guard !mix.isEmpty else { return [] }
        var excluded = Set(queued.map(\.id))
        excluded.insert(currentID)
        let recentEntries = history.values.sorted {
            if $0.lastPlayed != $1.lastPlayed { return $0.lastPlayed > $1.lastPlayed }
            return $0.hit.id < $1.hit.id
        }.prefix(Policy.recentTrackCount)
        excluded.formUnion(recentEntries.map { $0.hit.id })
        var excludedRecordings = Set((queued + recentEntries.map { $0.hit.asTrack }).map(recordingKey))
        if let current = mix.first(where: { $0.id == currentID }) {
            excludedRecordings.insert(recordingKey(current))
        }
        let freshMix = mix.enumerated().compactMap { index, track -> RecCandidate? in
            guard excluded.insert(track.id).inserted,
                  excludedRecordings.insert(recordingKey(track)).inserted else { return nil }
            return RecCandidate(track: track, mixIndex: index)
        }
        let profile = UserTasteProfile(history: history)
        let familiar = history.values.sorted { $0.hit.id < $1.hit.id }.compactMap { entry -> RecCandidate? in
            guard !excluded.contains(entry.hit.id),
                  !excludedRecordings.contains(recordingKey(entry.hit.asTrack)) else { return nil }
            if let skipped = entry.lastSkippedAt, (entry.earlySkips ?? 0) > 0,
               context.now.timeIntervalSince(skipped) < Policy.skipDecayDays * 86_400 { return nil }
            return RecCandidate(track: entry.hit.asTrack, mixIndex: nil)
        }
        let ranked = profile.eventCount == 0 ? freshMix :
            rank(freshMix + familiar, profile: profile, context: context, discovery: discovery)
        // Rotate exposure on refresh without randomizing away musical relevance.
        let rotated = ranked.filter { !recentlySuggested.contains($0.track.id) }
            + ranked.filter { recentlySuggested.contains($0.track.id) }
        return diversify(rotated, familiarShare: familiarShare(eventCount: profile.eventCount),
                         precedingArtists: queued.suffix(Policy.maxArtistRun).map { TrackFeatures(track: $0).primaryArtist })
    }
}
