import Foundation

/// Text metadata only: no inferred genre, BPM or acoustic energy.
struct TrackFeatures {
    let artists: Set<String>
    let primaryArtist: String?
    let artistIsReliable: Bool
    let titleTokens: Set<String>
    let versionTags: Set<VersionTag>
    let duration: TimeInterval?
    let allowsLongDuration: Bool

    init(track: Track) {
        self.init(rawTitle: track.cleanTitle ?? track.title, channel: nil,
                  structuredArtist: track.cleanArtist, duration: track.duration)
    }

    init(hit: TrackHit) {
        self.init(rawTitle: hit.title, channel: nil,
                  structuredArtist: hit.artist, duration: hit.duration)
    }

    init(rawTitle: String, channel: String?, structuredArtist: String? = nil,
         duration: TimeInterval? = nil) {
        let cleaned = MetadataCleaner.clean(rawTitle: rawTitle, channel: channel)
        let structured = structuredArtist?.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasStructured = !(structured ?? "").isEmpty
        let artist = hasStructured ? structured : cleaned.artist
        let names = MetadataCleaner.splitArtists(artist ?? "").map(MetadataCleaner.key).filter { !$0.isEmpty }
        artists = Set(names + cleaned.featured.map(MetadataCleaner.key).filter { !$0.isEmpty })
        primaryArtist = names.first
        artistIsReliable = hasStructured || cleaned.artistIsReliable
        titleTokens = Set(MetadataCleaner.key(MetadataCleaner.simplified(cleaned.title))
            .split(separator: " ").map(String.init))
        versionTags = cleaned.versionTags
        self.duration = duration.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
        allowsLongDuration = cleaned.versionTags.contains(.live) || titleTokens.contains("mix")
    }
}
