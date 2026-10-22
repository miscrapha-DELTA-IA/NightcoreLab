import Foundation

/// Public metadata only: preview URLs are never used as full-track audio.
/// Session injection keeps the entire catalog pipeline deterministic in tests.
actor MusicCatalogService {
    static let shared = MusicCatalogService()
    private let session: URLSession
    private var collections: [String: (Date, Track, [Track])] = [:]
    private struct StoredStream: Codable, Sendable {
        let videoID: String
        let expiresAt: Date
    }
    private static let streamTTL: TimeInterval = 7 * 24 * 60 * 60
    private let streamCacheURL: URL?
    private let initialStreams: Task<[String: StoredStream], Never>
    private var streamsLoaded = false
    private var streams: [String: StoredStream] = [:]
    private var streamWrite: Task<Void, Never>?
    init(session: URLSession = .shared, streamCacheURL: URL? = nil) {
        self.session = session
        let url = streamCacheURL ?? (session === URLSession.shared
            ? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
                .appendingPathComponent("Gnarly/catalog-streams-v1.json") : nil)
        self.streamCacheURL = url
        initialStreams = Task.detached(priority: .utility) {
            guard let url,
                  let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
                  size <= 256 * 1024, let data = try? Data(contentsOf: url),
                  let stored = try? JSONDecoder().decode([String: StoredStream].self, from: data) else { return [:] }
            let now = Date()
            let valid = stored.filter { key, value in
                key.count <= 512 && Self.validVideoID(value.videoID) && value.expiresAt > now &&
                    value.expiresAt.timeIntervalSince(now) <= Self.streamTTL
            }.sorted { $0.value.expiresAt > $1.value.expiresAt }.prefix(200)
            return Dictionary(uniqueKeysWithValues: valid.map { ($0.key, $0.value) })
        }
    }

    private static func validVideoID(_ value: String) -> Bool {
        value.range(of: "^[A-Za-z0-9_-]{11}$", options: .regularExpression) != nil
    }
    private static func streamKey(_ track: Track) -> String {
        [track.id, MetadataCleaner.key(cleanedTitle(track)),
         MetadataCleaner.key(AlbumArtistCollectionResolver.artistName(for: track) ?? "")].joined(separator: "|")
    }
    private func persistStreams() {
        guard let url = streamCacheURL else { return }
        let previous = streamWrite, snapshot = streams
        streamWrite = Task.detached(priority: .utility) {
            await previous?.value
            guard let data = try? JSONEncoder().encode(snapshot) else { return }
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: url, options: .atomic)
        }
    }
    func flushStreamCache() async { await streamWrite?.value }

    struct AppleSong: Decodable {
        var trackId: Int64?
        var trackName: String?
        var artistName: String?
        var collectionName: String?
        var collectionId: Int64?
        var artistId: Int64?
        var artworkUrl100: String?
        var trackNumber: Int?
        var trackTimeMillis: Double?
        var track: Track? {
            guard let id = trackId, let title = trackName,
                  let artist = artistName,
                  AlbumArtistCollectionResolver.normalize(artist) != nil else { return nil }
            return Track(id: "itunes-\(id)", title: title,
                thumbnailURL: artworkUrl100.flatMap { URL(string: $0.replacingOccurrences(of: "100x100bb", with: "600x600bb")) },
                cleanArtist: artist, cleanTitle: title, album: collectionName,
                duration: trackTimeMillis.map { $0 / 1000 }, trackNumber: trackNumber,
                catalogProvider: "itunes", collectionID: collectionId.map(String.init),
                artistID: artistId.map(String.init))
        }
    }
    private struct AppleResponse: Decodable { var results: [AppleSong] }
    private struct DeezerResponse: Decodable { var data: [DeezerSong] }
    private struct DeezerSong: Decodable {
        struct Artist: Decodable { var id: Int64; var name: String }
        struct Album: Decodable { var id: Int64; var title: String; var cover_xl: String? }
        var id: Int64; var title: String; var artist: Artist; var album: Album?
        var duration: Double?; var track_position: Int?
        var track: Track {
            Track(id: "deezer-\(id)", title: title, thumbnailURL: album?.cover_xl.flatMap(URL.init(string:)),
                cleanArtist: artist.name, cleanTitle: title, album: album?.title,
                duration: duration, trackNumber: track_position, catalogProvider: "deezer",
                collectionID: album.map { String($0.id) }, artistID: String(artist.id))
        }
    }

    static func cleanedTitle(_ track: Track) -> String {
        let artist = AlbumArtistCollectionResolver.artistName(for: track)
        var title = track.cleanTitle ?? track.title
        if let artist {
            for separator in [" - ", " – ", " — "] where title.hasPrefix(artist + separator) {
                title = String(title.dropFirst(artist.count + separator.count))
            }
        }
        return title.replacingOccurrences(of: "(?i)\\s*[\\[(](official[^\\])]*|lyrics?|audio|video)[\\])]", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
    static func query(for track: Track) -> String {
        [AlbumArtistCollectionResolver.artistName(for: track), cleanedTitle(track)]
            .compactMap { $0 }.joined(separator: " ")
    }

    private func request(_ base: String, _ params: [String: String] = [:]) throws -> URLRequest {
        guard var url = URLComponents(string: base) else { throw URLError(.badURL) }
        url.queryItems = params.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        guard let endpoint = url.url else { throw URLError(.badURL) }
        return URLRequest(url: endpoint, timeoutInterval: 12)
    }
    private func data(_ request: URLRequest) async throws -> Data {
        let (data, response) = try await session.data(for: request)
        try Task.checkCancellation()
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { throw URLError(.badServerResponse) }
        return data
    }
    private func apple(_ path: String, _ params: [String: String]) async throws -> [Track] {
        let bytes = try await data(request("https://itunes.apple.com/" + path, params))
        return try JSONDecoder().decode(AppleResponse.self, from: bytes).results.compactMap(\.track)
    }
    private func deezer(_ path: String, _ params: [String: String] = [:]) async throws -> [Track] {
        let bytes = try await data(request("https://api.deezer.com/" + path, params))
        return try JSONDecoder().decode(DeezerResponse.self, from: bytes).data.map(\.track)
    }
    static func bestMatch(_ candidates: [Track], for anchor: Track) -> Track? {
        let title = MetadataCleaner.key(cleanedTitle(anchor))
        let artist = AlbumArtistCollectionResolver.artistName(for: anchor)
        return candidates.filter { candidate in
            let key = MetadataCleaner.key(cleanedTitle(candidate))
            let titleMatches = key == title || title.hasSuffix(" " + key)
            let artistMatches = artist == nil || AlbumArtistCollectionResolver.normalize(artist) == AlbumArtistCollectionResolver.normalize(AlbumArtistCollectionResolver.artistName(for: candidate))
            return titleMatches && artistMatches
        }.first
    }

    /// Fetch once per anchor, reuse across mode switches. No audio downloads here.
    func collection(anchor: Track, local: [Track], mode: AlbumArtistMode) async -> AlbumArtistCollection {
        if let cached = collections[anchor.id], Date().timeIntervalSince(cached.0) < 900 {
            return AlbumArtistCollectionResolver.resolve(anchor: cached.1, candidates: local + cached.2, mode: mode)
        }
        var resolved = anchor
        var candidates: [Track] = []
        do {
            let found = try await apple("search", ["term": Self.query(for: anchor), "entity": "song", "limit": "5"])
            if let match = Self.bestMatch(found, for: anchor) { resolved = match }
        } catch { /* Next provider; local data remains visible. */ }
        if resolved.catalogProvider == nil, !Task.isCancelled {
            if let found = try? await deezer("search", ["q": Self.query(for: anchor), "limit": "5"]),
               let match = Self.bestMatch(found, for: anchor) { resolved = match }
        }
        if resolved.catalogProvider == nil, !Task.isCancelled,
           let found = try? await youtubeSearch(Self.query(for: anchor)),
           let match = Self.bestMatch(found, for: anchor) { resolved = match }
        if !Task.isCancelled {
            if resolved.catalogProvider == "itunes" {
                if let id = resolved.collectionID {
                    candidates += (try? await apple("lookup", ["id": id, "entity": "song", "limit": "200"])) ?? []
                }
                if let id = resolved.artistID {
                    candidates += (try? await apple("lookup", ["id": id, "entity": "song", "limit": "25"])) ?? []
                }
            } else if resolved.catalogProvider == "deezer" {
                if let id = resolved.collectionID {
                    var album = (try? await deezer("album/\(id)/tracks", ["limit": "1000"])) ?? []
                    for i in album.indices {
                        album[i].album = resolved.album
                        album[i].collectionID = id
                        if album[i].trackNumber == nil { album[i].trackNumber = i + 1 }
                    }
                    candidates += album
                }
                if let id = resolved.artistID { candidates += (try? await deezer("artist/\(id)/top", ["limit": "25"])) ?? [] }
            }
            if candidates.count < 15, let artist = AlbumArtistCollectionResolver.artistName(for: resolved) {
                candidates += (try? await youtubeSearch(artist)) ?? []
            }
        }
        // Keep the original playable/cached identity with the canonical metadata.
        let enriched = Track(id: anchor.id, title: resolved.cleanTitle ?? anchor.title,
            thumbnailURL: resolved.thumbnailURL ?? anchor.thumbnailURL, isCached: anchor.isCached,
            cleanArtist: resolved.cleanArtist, cleanTitle: resolved.cleanTitle,
            album: resolved.album, duration: resolved.duration, trackNumber: resolved.trackNumber,
            catalogProvider: resolved.catalogProvider, collectionID: resolved.collectionID,
            artistID: resolved.artistID, streamVideoID: anchor.streamVideoID)
        if !Task.isCancelled, !candidates.isEmpty {
            if collections.count >= 40 { collections.removeAll() }
            collections[anchor.id] = (Date(), enriched, candidates)
        }
        return AlbumArtistCollectionResolver.resolve(anchor: enriched, candidates: local + candidates, mode: mode)
    }

    /// Catalog IDs never reach /download as YouTube IDs. Resolve only on explicit demand.
    func playable(_ track: Track, baseURL: String) async throws -> Track {
        guard track.id.hasPrefix("itunes-") || track.id.hasPrefix("deezer-") else { return track }
        if let id = track.streamVideoID, Self.validVideoID(id) { return track }
        if !streamsLoaded {
            let restored = await initialStreams.value
            if !streamsLoaded { streams = restored; streamsLoaded = true }
        }
        try Task.checkCancellation()
        let key = Self.streamKey(track)
        if let cached = streams[key], cached.expiresAt > Date(), Self.validVideoID(cached.videoID) {
            var playable = track; playable.streamVideoID = cached.videoID
            return playable
        }
        let query = Self.query(for: track) + " audio"
        let backendRequest = try request(baseURL + "/v1/search", ["q": query])
        // A sleeping free Render service must not hold device-direct catalog
        // resolution behind its timeout. The first strict title/artist match
        // wins; cancellation tears down the slower metadata request.
        let match = await withTaskGroup(of: Track?.self, returning: Track?.self) { group in
            group.addTask {
                do {
                    let bytes = try await self.data(backendRequest)
                    let results = try JSONDecoder().decode([TrackHit].self, from: bytes).map(\.asTrack)
                    return Self.bestMatch(results, for: track)
                } catch { return nil }
            }
            group.addTask {
                do { return Self.bestMatch(try await self.youtubeSearch(query), for: track) }
                catch { return nil }
            }
            for await candidate in group {
                if let candidate, Self.validVideoID(candidate.id) {
                    group.cancelAll(); return candidate
                }
            }
            return nil
        }
        try Task.checkCancellation()
        guard let match else {
            throw URLError(.resourceUnavailable)
        }
        var playable = track
        playable.streamVideoID = match.id
        streams = streams.filter { $0.value.expiresAt > Date() }
        if streams.count >= 200, let oldest = streams.min(by: { $0.value.expiresAt < $1.value.expiresAt })?.key {
            streams[oldest] = nil
        }
        streams[key] = StoredStream(videoID: match.id, expiresAt: Date().addingTimeInterval(Self.streamTTL))
        persistStreams()
        return playable
    }

    /// InnerTube is an unofficial, changeable API. Parse only song rows and
    /// structured artist/album runs; never mistake an arbitrary video ID for metadata.
    func youtubeSearch(_ query: String) async throws -> [Track] {
        var req = try request("https://music.youtube.com/youtubei/v1/search")
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: [
            "context": ["client": ["clientName": "WEB_REMIX", "clientVersion": "1.20241009.01.00", "hl": "en"]],
            "query": query, "params": "EgWKAQIIAWoKEAkQBRAKEAMQBA%3D%3D"
        ])
        return try Self.parseYouTube(await data(req))
    }
    private static func parseYouTube(_ bytes: Data) throws -> [Track] {
        let root = try JSONSerialization.jsonObject(with: bytes)
        var output: [Track] = []
        func walk(_ node: Any) {
            if let dictionary = node as? [String: Any] {
                if let row = dictionary["musicResponsiveListItemRenderer"] as? [String: Any],
                   let playlist = row["playlistItemData"] as? [String: Any], let id = playlist["videoId"] as? String,
                   let columns = row["flexColumns"] as? [[String: Any]] {
                    var runs: [[String: Any]] = []
                    for column in columns {
                        let renderer = column["musicResponsiveListItemFlexColumnRenderer"] as? [String: Any]
                        let text = renderer?["text"] as? [String: Any]
                        runs += text?["runs"] as? [[String: Any]] ?? []
                    }
                    let title = runs.first?["text"] as? String ?? ""
                    var artist: String?, album: String?
                    for run in runs.dropFirst() {
                        let nav = run["navigationEndpoint"] as? [String: Any]
                        let browse = nav?["browseEndpoint"] as? [String: Any]
                        let browseID = browse?["browseId"] as? String ?? ""
                        if browseID.hasPrefix("UC") { artist = run["text"] as? String }
                        if browseID.hasPrefix("MPRE") { album = run["text"] as? String }
                    }
                    if !title.isEmpty, let artist {
                        output.append(Track(id: id, title: title,
                            thumbnailURL: URL(string: "https://i.ytimg.com/vi/\(id)/hqdefault.jpg"),
                            cleanArtist: artist, cleanTitle: title, album: album))
                    }
                }
                for value in dictionary.values { walk(value) }
            } else if let array = node as? [Any] { array.forEach(walk) }
        }
        walk(root)
        var seen = Set<String>()
        return output.filter { seen.insert($0.id).inserted }
    }
}
