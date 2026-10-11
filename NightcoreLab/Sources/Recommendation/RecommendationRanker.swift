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
        static let recentTrackCount = 10
        static let maxArtistRun = 2
        static let skipDecayDays = 21.0
        static let maxFamiliarShare = 0.7
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

    static func skipPenalty(_ entry: HistoryEntry, now: Date) -> Double {
        guard let skipped = entry.lastSkippedAt, (entry.earlySkips ?? 0) > 0 else { return 0 }
        let days = max(0, now.timeIntervalSince(skipped) / 86_400)
        let strength = min(1, Double(entry.earlySkips ?? 0) / Double(max(1, entry.plays)))
        return strength * exp(-days / Policy.skipDecayDays)
    }

    static func score(_ candidate: RecCandidate, profile: UserTasteProfile, context: RecContext) -> Double {
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
        return Weights.affinity * profile.affinity(for: features)
            + Weights.history * OmniboxRanker.frecency(entry, now: context.now)
            + Weights.mixOrder * prior + Weights.context * audioContext
            + (entry == nil ? Weights.novelty : 0)
            - Weights.skip * skip - durationPenalty
    }

    static func rank(_ candidates: [RecCandidate], profile: UserTasteProfile,
                     context: RecContext) -> [RecCandidate] {
        candidates.map { ($0, score($0, profile: profile, context: context)) }
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
        let unique = ranked.filter { seen.insert($0.track.id).inserted }
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

    static func recommendations(mix: [Track], history: [String: HistoryEntry],
                                currentID: String, queued: [Track], context: RecContext) -> [Track] {
        // Never substitute a history-only radio when /related fails or is empty.
        guard !mix.isEmpty else { return [] }
        var excluded = Set(queued.map(\.id))
        excluded.insert(currentID)
        let freshMix = mix.enumerated().compactMap { index, track -> RecCandidate? in
            guard excluded.insert(track.id).inserted else { return nil }
            return RecCandidate(track: track, mixIndex: index)
        }
        let profile = UserTasteProfile(history: history)
        // Cold-start precedence: preserve the exact existing Mix/queue order.
        guard profile.eventCount > 0 else { return freshMix.map(\.track) }
        let recent = Set(history.values.sorted {
            if $0.lastPlayed != $1.lastPlayed { return $0.lastPlayed > $1.lastPlayed }
            return $0.hit.id < $1.hit.id
        }.prefix(Policy.recentTrackCount).map { $0.hit.id })
        let familiar = history.values.sorted { $0.hit.id < $1.hit.id }.compactMap { entry -> RecCandidate? in
            guard !excluded.contains(entry.hit.id), !recent.contains(entry.hit.id) else { return nil }
            if let skipped = entry.lastSkippedAt, (entry.earlySkips ?? 0) > 0,
               context.now.timeIntervalSince(skipped) < Policy.skipDecayDays * 86_400 { return nil }
            return RecCandidate(track: entry.hit.asTrack, mixIndex: nil)
        }
        let ranked = rank(freshMix + familiar, profile: profile, context: context)
        return diversify(ranked, familiarShare: familiarShare(eventCount: profile.eventCount),
                         precedingArtists: queued.suffix(Policy.maxArtistRun).map { TrackFeatures(track: $0).primaryArtist })
    }
}
