import Foundation

/// Stores metadata and playback position, not audio bytes or security-scoped URLs.
struct SavedPlaybackSession: Codable, Equatable {
    let track: Track
    let position: TimeInterval
}

enum PlaybackSessionStorage {
    static let key = "nightcore.lastPlaybackSession"

    static func save(_ track: Track, at position: TimeInterval,
                     defaults: UserDefaults = .standard) {
        let safePosition = position.isFinite ? max(0, position) : 0
        let session = SavedPlaybackSession(track: track, position: safePosition)
        if let data = try? JSONEncoder().encode(session) {
            defaults.set(data, forKey: key)
        }
    }

    static func load(defaults: UserDefaults = .standard) -> SavedPlaybackSession? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(SavedPlaybackSession.self, from: data)
    }

    static func clear(defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: key)
    }
}
