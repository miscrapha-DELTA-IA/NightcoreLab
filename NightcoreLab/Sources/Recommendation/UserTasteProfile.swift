import Foundation

struct UserTasteProfile {
    let history: [String: HistoryEntry]
    let featuresByID: [String: TrackFeatures]
    let eventCount: Int
    let artists: [String: Double]
    let tokens: [String: Double]
    let versions: [VersionTag: Double]

    init(history: [String: HistoryEntry]) {
        self.history = history
        eventCount = history.values.reduce(0) { $0 + max(0, $1.plays) }
        var featuresByID: [String: TrackFeatures] = [:]
        var artists: [String: Double] = [:]
        var tokens: [String: Double] = [:]
        var versions: [VersionTag: Double] = [:]
        // Stable iteration keeps ties reproducible across runs.
        for entry in history.values.sorted(by: { $0.hit.id < $1.hit.id }) {
            let features = TrackFeatures(hit: entry.hit)
            featuresByID[entry.hit.id] = features
            let weight = log1p(Double(max(0, entry.plays))) + 2 * Double(max(0, entry.completions ?? 0))
            for artist in features.artists {
                artists[artist, default: 0] += weight * (features.artistIsReliable ? 1 : 0.35)
            }
            for token in features.titleTokens { tokens[token, default: 0] += weight }
            for tag in features.versionTags { versions[tag, default: 0] += weight }
        }
        self.featuresByID = featuresByID
        self.artists = Self.normalized(artists)
        self.tokens = Self.normalized(tokens)
        self.versions = Self.normalized(versions)
    }

    private static func normalized<Key: Hashable>(_ values: [Key: Double]) -> [Key: Double] {
        let peak = max(1, values.values.max() ?? 0)
        return values.mapValues { $0 / peak }
    }

    func affinity(for features: TrackFeatures) -> Double {
        let artist = features.artists.map { artists[$0] ?? 0 }.max() ?? 0
        let token = features.titleTokens.reduce(0.0) { $0 + (tokens[$1] ?? 0) }
            / Double(max(1, features.titleTokens.count))
        let version = features.versionTags.map { versions[$0] ?? 0 }.max() ?? 0
        return 0.7 * artist * (features.artistIsReliable ? 1 : 0.35) + 0.2 * token + 0.1 * version
    }
}
