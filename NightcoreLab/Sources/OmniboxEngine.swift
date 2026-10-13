import Foundation
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

    static func frecency(_ e: HistoryEntry?, now: Date) -> Double {
        guard let e else { return 0 }
        let freq = min(1, log1p(Double(e.plays)) / log1p(20))
        let days = max(0, now.timeIntervalSince(e.lastPlayed) / 86_400)
        return 0.6 * freq + 0.4 * exp(-days / 21)
    }
}

// MARK: - Engine

/// The cache is small and in-memory (NSCache retains at most 100 keys).
/// Its stale window is a resilience fallback, not a claim that results are fresh.
enum OmniboxCachePolicy {
    static let freshTTL: TimeInterval = 5 * 60
    static let staleTTL: TimeInterval = 24 * 60 * 60

    enum Freshness: Equatable {
        case fresh
        case stale
        case expired
    }

    static func freshness(savedAt: Date, now: Date = .now) -> Freshness {
        let age = now.timeIntervalSince(savedAt)
        guard age.isFinite, age >= 0 else { return .expired }
        if age <= freshTTL { return .fresh }
        return age <= staleTTL ? .stale : .expired
    }
}

enum OmniboxLoadState: Equatable {
    case idle
    case local
    case loading
    case partial
    case ready
    case failed
}

private enum OmniboxResponse: Sendable {
    case hits([TrackHit])
    case suggestions([String])
    case failedHits
    case failedSuggestions
}

@MainActor
@Observable
final class OmniboxEngine {
    private(set) var results: [TrackHit] = []
    private(set) var suggestions: [String] = []
    private(set) var directVideoID: String?
    private(set) var isSearching = false
    private(set) var lastRequestFailed = false
    private(set) var hasSearched = false
    private(set) var loadState: OmniboxLoadState = .idle
    private(set) var isShowingStaleCache = false

    @ObservationIgnored private var historyStore: PlayHistoryStore?
    private var history: [String: HistoryEntry] { historyStore?.entries ?? [:] }
    func useHistoryStore(_ store: PlayHistoryStore) { historyStore = store }

    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var requestGeneration = UUID()
    @ObservationIgnored private let cache = NSCache<NSString, Box>()
    @ObservationIgnored private var baseURL: URL
    @ObservationIgnored private let session: URLSession
    @ObservationIgnored private let debounce: Duration

    private final class Box {
        let hits: [TrackHit]
        let suggestions: [String]
        let savedAt: Date
        init(_ hits: [TrackHit], _ suggestions: [String], savedAt: Date = .now) {
            self.hits = hits
            self.suggestions = suggestions
            self.savedAt = savedAt
        }
    }

    init(baseURL: URL, session: URLSession? = nil,
         debounce: Duration = .milliseconds(220)) {
        self.baseURL = baseURL
        self.debounce = debounce
        if let session {
            self.session = session
        } else {
            let config = URLSessionConfiguration.ephemeral
            config.timeoutIntervalForRequest = 8
            self.session = URLSession(configuration: config)
        }
        cache.countLimit = 100
    }

    /// Invalidates even a late response that ignores URLSession cancellation.
    func useServer(_ newURL: URL) {
        guard baseURL != newURL else { return }
        task?.cancel()
        requestGeneration = UUID()
        baseURL = newURL
        cache.removeAllObjects() // Cached requests never cross server scopes.
        results = []
        suggestions = []
        directVideoID = nil
        isSearching = false
        hasSearched = false
        lastRequestFailed = false
        isShowingStaleCache = false
        loadState = .idle
    }

    /// Each edit starts a new generation. Cancellation alone is not a
    /// correctness boundary; no old generation may publish or cache results.
    func queryChanged(_ raw: String) {
        task?.cancel()
        requestGeneration = UUID()
        let generation = requestGeneration
        directVideoID = nil
        lastRequestFailed = false
        hasSearched = false
        isShowingStaleCache = false
        suggestions = []

        switch OmniboxIntent.classify(raw) {
        case .empty:
            results = []
            isSearching = false
            loadState = .idle
        case .direct(let id):
            results = []
            isSearching = false
            directVideoID = id
            loadState = .idle
        case .text(let query):
            // Keep only local matches for the newly typed query.
            results = OmniboxRanker.localMatches(query, history: history)
            isSearching = false
            loadState = .local
            guard query.count >= 2 else { return }

            let key = MetadataCleaner.key(query) as NSString
            let candidate = cache.object(forKey: key)
            let freshness = candidate.map {
                OmniboxCachePolicy.freshness(savedAt: $0.savedAt)
            } ?? .expired

            if let candidate, freshness != .expired {
                results = OmniboxRanker.rank(query: query, remote: candidate.hits,
                                            history: history)
                suggestions = candidate.suggestions
                hasSearched = true
                if freshness == .fresh {
                    loadState = .ready
                    return
                }
                isShowingStaleCache = true
            }

            let endpoint = baseURL
            isSearching = true
            loadState = isShowingStaleCache ? .partial : .loading
            task = Task { [weak self] in
                do { try await Task.sleep(for: self?.debounce ?? .milliseconds(220)) }
                catch { return }
                guard !Task.isCancelled, let self,
                      self.requestGeneration == generation else { return }

                var freshHits: [TrackHit]?
                var freshSuggestions: [String]?
                var hitsFailed = false
                var suggestionsFailed = false

                await withTaskGroup(of: OmniboxResponse.self) { group in
                    group.addTask {
                        do {
                            return .hits(try await self.fetch([TrackHit].self,
                                        path: "v1/search", query: query, endpoint: endpoint))
                        } catch { return .failedHits }
                    }
                    group.addTask {
                        do {
                            return .suggestions(try await self.fetch([String].self,
                                        path: "v1/suggest", query: query, endpoint: endpoint))
                        } catch { return .failedSuggestions }
                    }
                    for await response in group {
                        guard !Task.isCancelled,
                              self.requestGeneration == generation else {
                            group.cancelAll()
                            return
                        }
                        switch response {
                        case .hits(let hits):
                            freshHits = hits
                            self.results = OmniboxRanker.rank(query: query, remote: hits,
                                                               history: self.history)
                            self.isShowingStaleCache = false
                        case .suggestions(let values):
                            freshSuggestions = values
                            self.suggestions = values
                        case .failedHits:
                            hitsFailed = true
                        case .failedSuggestions:
                            suggestionsFailed = true
                        }
                        // Display the first successful part without awaiting the
                        // second endpoint. The spinner stays until both settle.
                        self.loadState = .partial
                    }
                }

                guard !Task.isCancelled,
                      self.requestGeneration == generation else { return }
                if let freshHits {
                    self.cache.setObject(Box(freshHits,
                        freshSuggestions ?? candidate?.suggestions ?? []),
                        forKey: key)
                }
                self.isSearching = false
                self.hasSearched = true
                self.lastRequestFailed = hitsFailed || suggestionsFailed
                if hitsFailed && freshHits == nil && freshSuggestions == nil &&
                   !self.isShowingStaleCache && self.results.isEmpty {
                    self.loadState = .failed
                } else if hitsFailed || suggestionsFailed || self.isShowingStaleCache {
                    self.loadState = .partial
                } else {
                    self.loadState = .ready
                }
            }
        }
    }

    private func fetch<T: Decodable>(_ type: T.Type, path: String, query: String,
                                     endpoint: URL) async throws -> T {
        var components = URLComponents(url: endpoint.appendingPathComponent(path),
                                       resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "q", value: query)]
        let (data, response) = try await session.data(from: components.url!)
        try Task.checkCancellation()
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
        return try JSONDecoder().decode(type, from: data)
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
