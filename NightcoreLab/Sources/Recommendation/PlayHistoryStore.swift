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
    static let earlySkipThreshold: TimeInterval = 10

    struct PendingSkip {
        let sessionID: UUID
        let trackID: String
    }
    private struct Session {
        let id = UUID()
        let trackID: String
        var completed = false
    }
    private var session: Session?
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

    /// Capture at manual selection, but commit only after the replacement starts.
    func pendingSkip(position: TimeInterval, duration: TimeInterval,
                     automaticAdvance: Bool) -> PendingSkip? {
        guard !automaticAdvance, let session, !session.completed,
              position.isFinite, position >= 0, position < Self.earlySkipThreshold,
              duration > 0, position < duration else { return nil }
        return PendingSkip(sessionID: session.id, trackID: session.trackID)
    }

    func beginPlayback(_ track: Track, sourceDuration: TimeInterval?,
                       replacing skip: PendingSkip? = nil, now: Date = .now) {
        if let skip, skip.sessionID == session?.id, session?.completed == false,
           skip.trackID != track.id {
            recordEarlySkip(skip.trackID, now: now)
        }
        let old = entries[track.id]?.hit
        let title = track.cleanTitle ?? (track.title == track.id ? old?.title : nil) ?? track.title
        let duration = track.duration ?? sourceDuration.flatMap { $0.isFinite && $0 > 0 ? $0 : nil } ?? old?.duration
        let hit = TrackHit(id: track.id, title: title,
            artist: track.cleanArtist ?? old?.artist ?? "", album: track.album ?? old?.album,
            duration: duration, thumb: track.thumbnailURL ?? old?.thumb,
            isSong: old?.isSong ?? true, explicit: old?.explicit ?? false)
        recordStart(hit, now: now)
        session = Session(trackID: track.id)
    }

    /// A restored track only counts once it actually starts. Pause/resume never adds a play.
    func resumePlaybackIfNeeded(_ track: Track, sourceDuration: TimeInterval?) {
        if session?.trackID != track.id || session?.completed == true {
            beginPlayback(track, sourceDuration: sourceDuration)
        }
    }

    func completePlayback(trackID: String) {
        guard var active = session, active.trackID == trackID, !active.completed else { return }
        active.completed = true
        session = active
        recordCompletion(trackID)
    }

    func endSession() { session = nil }

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
