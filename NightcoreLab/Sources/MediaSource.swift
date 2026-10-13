import Foundation

/// Provenance for future metadata gateways, separate from audio transport rights.
enum MediaSource: String, Codable, Hashable, Sendable {
    case youtube
    case spotify
    case local
}

/// Namespaces source identifiers; a Spotify catalog ID can never collide with
/// a YouTube video ID or a sandbox-owned local file identifier.
struct TrackIdentity: Hashable, Codable, Sendable {
    let source: MediaSource
    let sourceID: String

    init(source: MediaSource, sourceID: String) {
        self.source = source
        self.sourceID = sourceID
    }
}

extension Track {
    /// Legacy Track.id is still the canonical YouTube ID used by all existing
    /// caches, sessions and queue entries. Do not change its Codable payload.
    var identity: TrackIdentity { TrackIdentity(source: .youtube, sourceID: id) }
}
