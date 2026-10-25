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
enum LRCLIBRequestError: LocalizedError, Sendable {
    case rateLimited(retryAfter: TimeInterval?)
    case serviceUnavailable
    case httpStatus(Int)

    var errorDescription: String? {
        switch self {
        case .rateLimited(let seconds):
            if let seconds, seconds > 0 {
                return "O LRCLIB limitou as buscas. Aguarde \(Int(ceil(seconds))) segundos e tente novamente."
            }
            return "O LRCLIB limitou as buscas. Aguarde um pouco e tente novamente."
        case .serviceUnavailable:
            return "O serviço de letras está temporariamente indisponível. Tente novamente."
        case .httpStatus:
            return "Não foi possível consultar o serviço de letras. Tente novamente."
        }
    }
}

struct LRCLIBClient: Sendable {
    private static let base = URL(string: "https://lrclib.net/api")!
    static let userAgent = "NightcoreLab/1.0 (https://github.com/miscrapha-DELTA-IA/NightcoreLab)"
    private let session: URLSession

    init(session: URLSession? = nil) {
        if let session {
            self.session = session
        } else {
            let cfg = URLSessionConfiguration.ephemeral
            cfg.timeoutIntervalForRequest = 12
            cfg.waitsForConnectivity = false
            cfg.httpAdditionalHeaders = [
                "User-Agent": Self.userAgent,
                "Accept": "application/json"
            ]
            self.session = URLSession(configuration: cfg)
        }
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
        var request = URLRequest(url: comps.url!)
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, resp) = try await session.data(for: request)
        try Task.checkCancellation()
        guard let http = resp as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        let status = http.statusCode
        if status == 429 {
            let delay = http.value(forHTTPHeaderField: "Retry-After").flatMap(TimeInterval.init)
            // Do not retry during Retry-After: another request can extend the block.
            throw LRCLIBRequestError.rateLimited(retryAfter: delay)
        }
        if status == 503 { throw LRCLIBRequestError.serviceUnavailable }
        guard (200..<300).contains(status) || status == 404 else {
            throw LRCLIBRequestError.httpStatus(status)
        }
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
