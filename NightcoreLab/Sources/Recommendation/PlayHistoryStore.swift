import Foundation
import Observation

struct HistoryEntry: Codable, Sendable {
    let hit: TrackHit
    var plays: Int
    var lastPlayed: Date
    // Optional for compatibility with the original omnibox.playHistory JSON.
    var completions: Int? = nil
    var earlySkips: Int? = nil
    var lastSkippedAt: Date? = nil
}

@MainActor
@Observable
final class PlayHistoryStore {
    static let defaultsKey = "omnibox.playHistory"
    static let entryLimit = 100
    private(set) var entries: [String: HistoryEntry]
    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.defaultsKey),
           let decoded = try? JSONDecoder().decode([String: HistoryEntry].self, from: data) {
            entries = decoded
        } else {
            entries = [:]
        }
    }

    func recordStart(_ hit: TrackHit, now: Date = .now) {
        let previous = entries[hit.id]
        entries[hit.id] = HistoryEntry(hit: hit, plays: (previous?.plays ?? 0) + 1,
            lastPlayed: now, completions: previous?.completions,
            earlySkips: previous?.earlySkips, lastSkippedAt: previous?.lastSkippedAt)
        persist()
    }

    func recordCompletion(_ id: String) {
        guard var entry = entries[id] else { return }
        entry.completions = (entry.completions ?? 0) + 1
        entries[id] = entry
        persist()
    }

    func recordEarlySkip(_ id: String, now: Date = .now) {
        guard var entry = entries[id] else { return }
        entry.earlySkips = (entry.earlySkips ?? 0) + 1
        entry.lastSkippedAt = now
        entries[id] = entry
        persist()
    }

    private func persist() {
        let recent = entries.values.sorted {
            if $0.lastPlayed != $1.lastPlayed { return $0.lastPlayed > $1.lastPlayed }
            return $0.hit.id < $1.hit.id
        }.prefix(Self.entryLimit)
        entries = Dictionary(recent.map { ($0.hit.id, $0) }, uniquingKeysWith: { first, _ in first })
        if let data = try? JSONEncoder().encode(entries) {
            defaults.set(data, forKey: Self.defaultsKey)
        }
    }
}
