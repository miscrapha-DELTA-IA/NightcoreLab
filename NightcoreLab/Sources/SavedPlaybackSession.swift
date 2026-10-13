import Foundation

/// Persist only metadata and source-audio position, never audio bytes or
/// security-scoped URLs. V2 adds a schema marker to the original JSON shape:
/// older NightcoreLab builds ignore this unknown key when decoding.
struct SavedPlaybackSession: Codable, Equatable {
    static let currentSchemaVersion = 2

    let track: Track
    let position: TimeInterval
    let schemaVersion: Int

    init(track: Track, position: TimeInterval) {
        self.track = track
        self.position = position.isFinite ? max(0, position) : 0
        self.schemaVersion = Self.currentSchemaVersion
    }

    private enum CodingKeys: String, CodingKey {
        case track, position, schemaVersion
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // Sessions written before Stage 17B have no schemaVersion.
        let version = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        guard version == 1 || version == Self.currentSchemaVersion else {
            throw DecodingError.dataCorruptedError(forKey: .schemaVersion,
                in: container, debugDescription: "Unsupported playback session schema")
        }
        let position = try container.decode(TimeInterval.self, forKey: .position)
        guard position.isFinite, position >= 0 else {
            throw DecodingError.dataCorruptedError(forKey: .position,
                in: container, debugDescription: "Invalid playback position")
        }
        self.track = try container.decode(Track.self, forKey: .track)
        self.position = position
        // Re-encoding migrates legacy sessions to v2 without writing a second copy.
        self.schemaVersion = Self.currentSchemaVersion
    }
}

enum PlaybackSessionStorage {
    /// Preserve this key and the original JSON fields to avoid migration loss.
    static let key = "nightcore.lastPlaybackSession"

    static func save(_ track: Track, at position: TimeInterval,
                     defaults: UserDefaults = .standard) {
        let session = SavedPlaybackSession(track: track, position: position)
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
