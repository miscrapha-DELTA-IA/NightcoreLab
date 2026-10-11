import Foundation

/// LRCLIB metadata is needed to avoid mistaking the first search hit for the song.
struct LyricsRecord: Decodable, Identifiable, Equatable {
    let id: Int
    let trackName: String
    let artistName: String
    let duration: TimeInterval
    let syncedLyrics: String?
    let plainLyrics: String?
    let instrumental: Bool?

    var hasLyrics: Bool {
        !(syncedLyrics ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
        !(plainLyrics ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

struct LyricsIdentity: Equatable {
    let title: String
    let artist: String?
}

struct LyricsLookup {
    let suggestions: [LyricsRecord]
    let automatic: LyricsRecord?
}

/// Pure matching rules. Conservative defaults avoid showing the lyrics of another
/// recording just because its artist or album matches the YouTube search query.
enum LyricsMatcher {
    static func identity(from rawTitle: String) -> LyricsIdentity? {
        let rawTitle = rawTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rawTitle.isEmpty,
              rawTitle.range(of: #"^[a-zA-Z0-9_-]{11}$"#, options: .regularExpression) == nil
        else { return nil }
        let separators = [" - ", " – ", " — "]
        if let separator = separators.first(where: { rawTitle.contains($0) }) {
            let parts = rawTitle.components(separatedBy: separator)
            if parts.count >= 2 {
                let artist = clean(parts[0])
                let title = clean(parts.dropFirst().joined(separator: separator))
                if !artist.isEmpty && !title.isEmpty {
                    return LyricsIdentity(title: title, artist: artist)
                }
            }
        }
        let title = clean(rawTitle)
        return title.isEmpty ? nil : LyricsIdentity(title: title, artist: nil)
    }

    static func clean(_ raw: String) -> String {
        var title = raw
        // Remove YouTube presentation labels, but do not discard genuine song
        // titles or bracketed words unless the bracket is a known media qualifier.
        let qualifiers = #"\([^)]*(?:official|music video|lyrics?|visuali[sz]er|audio|slowed|nightcore|reverb|sped up|edit|remaster|4k|8d|bass boosted)[^)]*\)|\[[^\]]*(?:official|music video|lyrics?|visuali[sz]er|audio|slowed|nightcore|reverb|sped up|edit|remaster|4k|8d|bass boosted)[^\]]*\]"#
        title = title.replacingOccurrences(of: qualifiers, with: "",
                                           options: [.regularExpression, .caseInsensitive])
        title = title.replacingOccurrences(
            of: #"(?i)\s*[|]\s*(?:official|lyrics?|music video|audio|visuali[sz]er).*$"#,
            with: "", options: .regularExpression)
        title = title.replacingOccurrences(
            of: #"(?i)\s+(?:official (?:music )?video|official audio|lyric video)$"#,
            with: "", options: .regularExpression)
        return title.trimmingCharacters(in: .whitespacesAndNewlines.union(
            CharacterSet(charactersIn: "-–—|:")))
    }

    static func normalized(_ text: String) -> String {
        let folded = text.folding(options: [.caseInsensitive, .diacriticInsensitive],
                                  locale: Locale(identifier: "en_US_POSIX"))
        return folded.lowercased()
            .replacingOccurrences(of: #"[^a-z0-9]+"#, with: " ",
                                  options: .regularExpression)
            .split(separator: " ").joined(separator: " ")
    }

    static func similarity(_ a: String, _ b: String) -> Double {
        let left = normalized(a)
        let right = normalized(b)
        if !left.isEmpty && left == right { return 1 }
        let tokensA = Set(left.split(separator: " "))
        let tokensB = Set(right.split(separator: " "))
        guard !tokensA.isEmpty && !tokensB.isEmpty else { return 0 }
        let matches = Double(tokensA.intersection(tokensB).count)
        return 2 * matches / Double(tokensA.count + tokensB.count)
    }

    static func isTrusted(_ candidate: LyricsRecord, identity: LyricsIdentity,
                          audioDuration: TimeInterval) -> Bool {
        guard candidate.hasLyrics, candidate.instrumental != true,
              audioDuration.isFinite, audioDuration > 0,
              candidate.duration.isFinite, candidate.duration > 0 else { return false }
        let titleScore = similarity(identity.title, candidate.trackName)
        // An artist-less YouTube title is inherently ambiguous. Require an exact
        // title AND a close duration, or let the listener pick manually.
        let tolerance = identity.artist == nil ? 3.0 : min(12, max(5, audioDuration * 0.04))
        guard abs(audioDuration - candidate.duration) <= tolerance else { return false }
        if let artist = identity.artist {
            return titleScore >= 0.88 && similarity(artist, candidate.artistName) >= 0.85
        }
        return titleScore == 1
    }

    static func best(_ records: [LyricsRecord], youtubeTitle: String,
                     audioDuration: TimeInterval) -> LyricsRecord? {
        guard let identity = identity(from: youtubeTitle) else { return nil }
        return records.filter { isTrusted($0, identity: identity, audioDuration: audioDuration) }
            .min { left, right in
                abs(left.duration - audioDuration) < abs(right.duration - audioDuration)
            }
    }

    static func sorted(_ records: [LyricsRecord], for identity: LyricsIdentity?,
                       audioDuration: TimeInterval) -> [LyricsRecord] {
        let distinct = Dictionary(grouping: records.filter(\.hasLyrics), by: \.id)
            .compactMap { $0.value.first }
        guard let identity else { return distinct.sorted { $0.id < $1.id } }
        func score(_ record: LyricsRecord) -> Double {
            let title = similarity(identity.title, record.trackName)
            let artist = identity.artist.map { similarity($0, record.artistName) } ?? 0
            let duration = audioDuration > 0
                ? max(0, 1 - abs(record.duration - audioDuration) / 30)
                : 0
            return title * 6 + artist * 3 + duration
        }
        return distinct.sorted { a, b in
            let left = score(a), right = score(b)
            return left == right ? a.id < b.id : left > right
        }
    }
}

enum LyricsService {
    static func search(for track: Track, audioDuration: TimeInterval) async throws -> LyricsLookup {
        let identity = LyricsMatcher.identity(from: track.title)
        guard let identity else { return LyricsLookup(suggestions: [], automatic: nil) }
        let records = try await request(queryItems: [
            URLQueryItem(name: "track_name", value: identity.title),
            URLQueryItem(name: "artist_name", value: identity.artist)
        ].filter { $0.value != nil })
        let sorted = LyricsMatcher.sorted(records, for: identity, audioDuration: audioDuration)
        let choice = LyricsMatcher.best(sorted, youtubeTitle: track.title, audioDuration: audioDuration)
        return LyricsLookup(suggestions: sorted, automatic: choice)
    }

    static func searchManually(_ query: String) async throws -> [LyricsRecord] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        return try await request(queryItems: [URLQueryItem(name: "q", value: trimmed)])
            .filter(\.hasLyrics)
    }

    private static func request(queryItems: [URLQueryItem]) async throws -> [LyricsRecord] {
        guard var components = URLComponents(string: "https://lrclib.net/api/search") else {
            throw URLError(.badURL)
        }
        components.queryItems = queryItems
        guard let url = components.url else { throw URLError(.badURL) }
        var request = URLRequest(url: url, timeoutInterval: 12)
        request.setValue("NightcoreLab/1.0 (SwiftUI lyrics)", forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        try Task.checkCancellation()
        guard let status = (response as? HTTPURLResponse)?.statusCode else {
            throw URLError(.badServerResponse)
        }
        if status == 404 { return [] }
        if status == 429 { throw URLError(.resourceUnavailable) }
        guard status == 200 else { throw URLError(.badServerResponse) }
        return try JSONDecoder().decode([LyricsRecord].self, from: data)
    }
}
