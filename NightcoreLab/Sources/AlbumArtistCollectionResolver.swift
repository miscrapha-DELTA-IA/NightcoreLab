import Foundation

enum AlbumArtistMode: String, CaseIterable, Identifiable, Sendable {
    case album, artist, both
    var id: String { rawValue }
}

struct AlbumArtistCollection: Sendable {
    let anchor: Track
    let mode: AlbumArtistMode
    let albumTitle: String?
    let artistName: String?
    let albumTracks: [Track]
    let artistTracks: [Track]
    let usedArtistFallback: Bool

    var playbackTracks: [Track] { albumTracks + artistTracks }
    var fallbackNotice: String? {
        guard usedArtistFallback else { return nil }
        return "Sem álbum completo • Mostrando músicas de \(artistName ?? "mesmo artista")"
    }
}

/// Pure, local and deterministic: never accesses the network or transport.
enum AlbumArtistCollectionResolver {
    private static let emptyLabels: Set<String> = [
        "nao identificado", "artista nao identificado", "nao informado", "unknown", "unknown album", "unknown artist", "single", "singles",
        "album", "untitled", "n a", "na", "none", "various", "various artists"
    ]

    static func normalize(_ text: String?) -> String? {
        guard let text else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let folded = trimmed.folding(options: [.caseInsensitive, .diacriticInsensitive],
                                     locale: Locale(identifier: "en_US_POSIX"))
            .replacingOccurrences(of: "[^\\p{L}\\p{N}]+", with: " ",
                                  options: .regularExpression)
            .split(separator: " ").joined(separator: " ")
        return folded.isEmpty || emptyLabels.contains(folded) ? nil : folded
    }

    static func albumTitle(for track: Track) -> String? {
        normalize(track.album) == nil ? nil :
            track.album?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func artistName(for track: Track) -> String? {
        if normalize(track.cleanArtist) != nil {
            return track.cleanArtist?.replacingOccurrences(of: "(?i)\\s*(-\\s*topic|official artist channel|official|vevo)$", with: "", options: .regularExpression).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        // Generic YouTube and old ID3 data often embed Artist - Title.
        for separator in [" - ", " – ", " — "] {
            let parts = track.title.components(separatedBy: separator)
            if parts.count > 1, let candidate = parts.first,
               normalize(candidate) != nil {
                return candidate.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return nil
    }

    private static func artistKey(_ track: Track) -> String? {
        guard let artist = artistName(for: track) else { return nil }
        let clean = artist.replacingOccurrences(
            of: "(?i)\\s*(-\\s*topic|official artist channel|official|vevo)$",
            with: "", options: .regularExpression)
        return normalize(clean)
    }

    static func resolve(anchor: Track, candidates: [Track],
                        mode: AlbumArtistMode = .both) -> AlbumArtistCollection {
        // Merge metadata across cached/history/search copies of the same ID;
        // a sparse playback track must not discard an album from a richer cache.
        var tracks: [Track] = []
        var positions: [String: Int] = [:]
        for candidate in [anchor] + candidates {
            if let index = positions[candidate.id] {
                var current = tracks[index]
                if normalize(current.album) == nil, normalize(candidate.album) != nil {
                    current.album = candidate.album
                }
                if normalize(current.cleanArtist) == nil, normalize(candidate.cleanArtist) != nil {
                    current.cleanArtist = candidate.cleanArtist
                }
                if current.trackNumber == nil { current.trackNumber = candidate.trackNumber }
                if current.cleanTitle == nil { current.cleanTitle = candidate.cleanTitle }
                if current.duration == nil { current.duration = candidate.duration }
                tracks[index] = current
            } else {
                positions[candidate.id] = tracks.count
                tracks.append(candidate)
            }
        }
        // Prefer local identities when the same recording is in a catalog.
        var recordings = Set<String>()
        tracks = tracks.filter { track in
            let artist = artistKey(track) ?? track.id
            let title = normalize(track.cleanTitle ?? track.title) ?? track.id
            return recordings.insert(artist + "|" + title).inserted
        }
        let anchor = tracks[0]
        let album = albumTitle(for: anchor)
        let albumKey = normalize(album)
        let artist = artistName(for: anchor)
        let key = artistKey(anchor)
        let matchedAlbum = tracks.filter { track in
            guard let albumKey, normalize(track.album) == albumKey else { return false }
            guard let key, let other = artistKey(track) else { return true }
            return key == other
        }
        // Explicit ID3 track numbers sort the album; missing numbers keep source order.
        let orderedAlbum = matchedAlbum.allSatisfy({ $0.trackNumber != nil })
            ? matchedAlbum.enumerated().sorted { lhs, rhs in
                if lhs.element.trackNumber != rhs.element.trackNumber {
                    return lhs.element.trackNumber! < rhs.element.trackNumber!
                }
                return lhs.offset < rhs.offset
            }.map(\.element) : matchedAlbum
        let byArtist = tracks.filter { track in
            guard let key, let other = artistKey(track) else { return false }
            return key == other
        }
        let albumComplete = orderedAlbum.count >= 2
        let albumTracks: [Track]
        let artistTracks: [Track]
        let fallback: Bool
        switch mode {
        case .album:
            fallback = !albumComplete
            albumTracks = albumComplete ? orderedAlbum : []
            artistTracks = albumComplete ? [] : (byArtist.isEmpty ? [anchor] : byArtist)
        case .artist:
            fallback = false
            albumTracks = []
            artistTracks = byArtist.isEmpty ? [anchor] : byArtist
        case .both:
            fallback = !albumComplete
            albumTracks = albumComplete ? orderedAlbum : []
            let albumIDs = Set(albumTracks.map(\.id))
            artistTracks = (byArtist.isEmpty ? [anchor] : byArtist)
                .filter { !albumIDs.contains($0.id) }
        }
        return AlbumArtistCollection(anchor: anchor, mode: mode,
            albumTitle: album, artistName: artist,
            albumTracks: albumTracks, artistTracks: artistTracks,
            usedArtistFallback: fallback)
    }
}
