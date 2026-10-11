import Foundation
import Observation
import Observation

// =============================================================================
// Omnibox: resultados do YT Music (via seu backend) + histórico local, re-ranqueados.
// Custo no aparelho: debounce 220 ms, 1 requisição cancelável, NSCache, ranking O(n·tokens) com n ≤ 20.
// =============================================================================

struct TrackHit: Identifiable, Hashable, Sendable, Codable {
    let id: String                 // videoID
    let title: String
    let artist: String
    let album: String?
    let duration: TimeInterval?
    let thumb: URL?
    let isSong: Bool
    let explicit: Bool
}

struct HistoryEntry: Codable, Sendable {
    let hit: TrackHit
    var plays: Int
    var lastPlayed: Date
}

enum OmniboxIntent: Equatable {
    case empty
    case direct(videoID: String)   // colou link ou ID: pula a busca
    case text(String)

    static func classify(_ input: String) -> OmniboxIntent {
        let s = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.isEmpty { return .empty }

        if let url = URL(string: s), let host = url.host?.lowercased(),
           host.hasSuffix("youtube.com") || host == "youtu.be" {
            if host == "youtu.be" { let id = url.lastPathComponent; if isVideoID(id) { return .direct(videoID: id) } }
            if let v = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "v" })?.value, isVideoID(v) { return .direct(videoID: v) }
        }
        // ID "solto": exige dígito, "_", "-" ou caixa mista, para não confundir com a palavra "mockingbird".
        if s.count == 11, isVideoID(s),
           s.contains(where: { $0.isNumber || $0 == "_" || $0 == "-" }) || (s.contains(where: \.isUppercase) && s.contains(where: \.isLowercase)) {
            return .direct(videoID: s)
        }
        return .text(s)
    }

    private static func isVideoID(_ s: String) -> Bool {
        s.count == 11 && s.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-") }
    }
}

// MARK: - Ranking

enum OmniboxRanker {

    static func rank(query: String, remote: [TrackHit], history: [String: HistoryEntry], now: Date = .now) -> [TrackHit] {
        let qKey = MetadataCleaner.key(query)
        let qTokens = qKey.split(separator: " ").map(String.init)
        let wantsLong = qKey.contains("mix") || qKey.contains("live") || qKey.contains("hour") || qKey.contains(" set")

        // Candidatos = remotos (ordem do YT vira "prior") + itens do histórico que o remoto não trouxe.
        var candidates: [(hit: TrackHit, index: Int)] = remote.enumerated().map { ($1, $0) }
        let remoteIDs = Set(remote.map(\.id))
        for e in history.values where !remoteIDs.contains(e.hit.id) && coverage(qTokens, of: e.hit) >= 0.99 {
            candidates.append((e.hit, 3))
        }

        var best: [String: (hit: TrackHit, score: Double)] = [:]
        for (hit, i) in candidates {
            let hay = hit.artist + " " + hit.title
            let text = max(Similarity.score(query, hay), 0.9 * Similarity.score(query, hit.title), 0.95 * coverage(qTokens, of: hit))
            let prior = 1.0 / (1.0 + 0.35 * Double(i))
            let frec = frecency(history[hit.id], now: now)
            var penalty = 0.0
            if let d = hit.duration, (d < 45 || d > 720), !wantsLong { penalty = 0.25 }

            let score = 0.45 * text + 0.30 * prior + 0.15 * frec + (hit.isSong ? 0.05 : 0) - penalty
            let dedupe = MetadataCleaner.key(hit.artist + " " + hit.title)       // mesma faixa, vários uploads
            if score > (best[dedupe]?.score ?? -1) { best[dedupe] = (hit, score) }
        }
        return best.values.sorted { $0.score > $1.score }.prefix(10).map(\.hit)
    }

    /// Resultado instantâneo (antes da rede): só histórico.
    static func localMatches(_ query: String, history: [String: HistoryEntry], now: Date = .now) -> [TrackHit] {
        let tokens = MetadataCleaner.key(query).split(separator: " ").map(String.init)
        guard !tokens.isEmpty else { return [] }
        return history.values
            .filter { coverage(tokens, of: $0.hit) >= 0.99 }
            .sorted { frecency($0, now: now) > frecency($1, now: now) }
            .prefix(3).map(\.hit)
    }

    /// Fração dos tokens digitados que casam (exato ou prefixo) com artista+título. Cobre digitação parcial.
    static func coverage(_ qTokens: [String], of hit: TrackHit) -> Double {
        if qTokens.isEmpty { return 0 }
        let hay = MetadataCleaner.key(hit.artist + " " + hit.title).split(separator: " ")
        let matched = qTokens.filter { q in hay.contains { $0.hasPrefix(q) } }.count
        return Double(matched) / Double(qTokens.count)
    }

    private static func frecency(_ e: HistoryEntry?, now: Date) -> Double {
        guard let e else { return 0 }
        let freq = min(1, log1p(Double(e.plays)) / log1p(20))
        let days = max(0, now.timeIntervalSince(e.lastPlayed) / 86_400)
        return 0.6 * freq + 0.4 * exp(-days / 21)
    }
}

// MARK: - Engine

@MainActor
@Observable
final class OmniboxEngine {
    private(set) var results: [TrackHit] = []
    private(set) var suggestions: [String] = []
    private(set) var directVideoID: String?          // link/ID colado: o app resolve direto
    private(set) var isSearching = false

    /// O app mantém isto atualizado (videoID -> reproduções/última vez).
    @ObservationIgnored var history: [String: HistoryEntry] = [:]

    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private let cache = NSCache<NSString, Box>()
    private var baseURL: URL
    private let session: URLSession

    private final class Box { let hits: [TrackHit]; let sugg: [String]
        init(_ h: [TrackHit], _ s: [String]) { hits = h; sugg = s } }

    init(baseURL: URL) {
        self.baseURL = baseURL
        if let stored = UserDefaults.standard.data(forKey: "omnibox.playHistory"),
           let decoded = try? JSONDecoder().decode([String: HistoryEntry].self, from: stored) {
            history = decoded
        }
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 8
        session = URLSession(configuration: cfg)
        cache.countLimit = 100
    }

    func useServer(_ newURL: URL) {
        guard baseURL != newURL else { return }
        task?.cancel()
        baseURL = newURL
        cache.removeAllObjects()
        isSearching = false
    }

    /// Registra a escolha da música; persiste frecency mesmo após fechar Karaoke Mode.
    func recordPlay(_ hit: TrackHit) {
        let previous = history[hit.id]
        history[hit.id] = HistoryEntry(hit: hit, plays: (previous?.plays ?? 0) + 1,
                                       lastPlayed: .now)
        // Armazenar apenas 100 itens recentes para evitar crescimento indefinido.
        if history.count > 100 {
            for entry in history.sorted(by: { $0.value.lastPlayed < $1.value.lastPlayed })
                .prefix(history.count - 100) {
                history.removeValue(forKey: entry.key)
            }
        }
        if let data = try? JSONEncoder().encode(history) {
            UserDefaults.standard.set(data, forKey: "omnibox.playHistory")
        }
    }

    /// Chame em `.onChange(of: text)`.
    func queryChanged(_ raw: String) {
        task?.cancel()
        directVideoID = nil

        switch OmniboxIntent.classify(raw) {
        case .empty:
            results = []; suggestions = []; isSearching = false
        case .direct(let id):
            results = []; suggestions = []; isSearching = false; directVideoID = id
        case .text(let q):
            results = OmniboxRanker.localMatches(q, history: history)         // instantâneo
            guard q.count >= 2 else { return }

            let key = MetadataCleaner.key(q) as NSString
            if let cached = cache.object(forKey: key) {
                results = OmniboxRanker.rank(query: q, remote: cached.hits, history: history)
                suggestions = cached.sugg; isSearching = false
                return
            }
            isSearching = true
            task = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(220))                 // debounce
                guard !Task.isCancelled, let self else { return }
                do {
                    async let hits = self.fetch([TrackHit].self, "v1/search", q)
                    async let sugg = self.fetch([String].self, "v1/suggest", q)
                    let (h, s) = (try await hits, (try? await sugg) ?? [])
                    guard !Task.isCancelled else { return }
                    self.cache.setObject(Box(h, s), forKey: key)
                    self.results = OmniboxRanker.rank(query: q, remote: h, history: self.history)
                    self.suggestions = s
                    self.isSearching = false
                } catch {
                    if Task.isCancelled || (error as? URLError)?.code == .cancelled { return }
                    self.isSearching = false          // falha de rede: mantém o que já está na tela (histórico)
                }
            }
        }
    }

    private nonisolated func fetch<T: Decodable>(_ type: T.Type, _ path: String, _ q: String) async throws -> T {
        var comps = URLComponents(url: baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        comps.queryItems = [URLQueryItem(name: "q", value: q)]
        let (data, resp) = try await session.data(from: comps.url!)
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        return try JSONDecoder().decode(T.self, from: data)
    }
}
extension TrackHit {
    var asTrack: Track {
        Track(id: id, title: title,
              thumbnailURL: thumb ?? URL(string: "https://i.ytimg.com/vi/\(id)/hqdefault.jpg"),
              cleanArtist: artist.isEmpty ? nil : artist,
              cleanTitle: title, album: album, duration: duration)
    }
}
