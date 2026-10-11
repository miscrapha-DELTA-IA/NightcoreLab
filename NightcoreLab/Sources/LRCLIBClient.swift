import Foundation

struct LRCLIBRecord: Codable, Hashable, Sendable, Identifiable {
    let id: Int
    let trackName: String
    let artistName: String
    let albumName: String?
    let duration: Double?
    let instrumental: Bool?
    let plainLyrics: String?
    let syncedLyrics: String?

    var hasSynced: Bool { !(syncedLyrics ?? "").isEmpty }
    /// Enhanced LRC (tags <mm:ss.xx> por palavra) — raro, mas vale prioridade.
    var hasWordSync: Bool {
        syncedLyrics?.range(of: #"<\d{1,2}:\d{2}"#, options: .regularExpression) != nil
    }
}

/// Endpoints usados (docs oficiais do LRCLIB):
/// - GET /api/get     -> match exato; com `duration` só responde se a diferença for ≤ 2 s
/// - GET /api/search  -> mais lento e menos preciso; usar só como fallback, com campos específicos
struct LRCLIBClient: Sendable {
    private static let base = URL(string: "https://lrclib.net/api")!
    private let session: URLSession

    init() {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 6
        cfg.waitsForConnectivity = false
        cfg.httpAdditionalHeaders = [
            "User-Agent": "NightcoreLab/1.0 (+https://github.com/miscrapha-DELTA-IA/NightcoreLab)"
        ]
        session = URLSession(configuration: cfg)
    }

    /// nil = 404 (sem registro compatível).
    func get(track: String, artist: String, album: String?, duration: TimeInterval?) async throws -> LRCLIBRecord? {
        var items = [URLQueryItem(name: "track_name", value: track),
                     URLQueryItem(name: "artist_name", value: artist)]
        if let album, !album.isEmpty { items.append(.init(name: "album_name", value: album)) }
        if let duration { items.append(.init(name: "duration", value: String(Int(duration.rounded())))) }
        let (data, status) = try await fetch("get", items)
        if status == 404 { return nil }
        return try JSONDecoder().decode(LRCLIBRecord.self, from: data)
    }

    func search(track: String, artist: String?) async throws -> [LRCLIBRecord] {
        var items = [URLQueryItem(name: "track_name", value: track)]
        if let artist, !artist.isEmpty { items.append(.init(name: "artist_name", value: artist)) }
        return try await searchRequest(items)
    }

    func search(q: String) async throws -> [LRCLIBRecord] {
        try await searchRequest([URLQueryItem(name: "q", value: q)])
    }

    // MARK: -

    private func searchRequest(_ items: [URLQueryItem]) async throws -> [LRCLIBRecord] {
        let (data, status) = try await fetch("search", items)
        if status == 404 { return [] }
        return try JSONDecoder().decode([LRCLIBRecord].self, from: data)
    }

    private func fetch(_ path: String, _ items: [URLQueryItem]) async throws -> (Data, Int) {
        var comps = URLComponents(url: Self.base.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        comps.queryItems = items
        let (data, resp) = try await session.data(from: comps.url!)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) || status == 404 else { throw URLError(.badServerResponse) }
        return (data, status)
    }
}
extension LRCLIBRecord {
    init(legacy: LyricsRecord) {
        self.init(id: legacy.id, trackName: legacy.trackName,
                  artistName: legacy.artistName, albumName: nil,
                  duration: legacy.duration, instrumental: legacy.instrumental,
                  plainLyrics: legacy.plainLyrics, syncedLyrics: legacy.syncedLyrics)
    }

    var asLegacyRecord: LyricsRecord {
        LyricsRecord(id: id, trackName: trackName, artistName: artistName,
                     duration: duration ?? 0, syncedLyrics: syncedLyrics,
                     plainLyrics: plainLyrics, instrumental: instrumental)
    }
}
