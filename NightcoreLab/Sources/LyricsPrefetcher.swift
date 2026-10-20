import Foundation

// MARK: - Cache em disco (Caches/lyrics/<videoID>.json)

struct CachedLyricsChoice: Codable, Sendable {
    var selected: LRCLIBRecord?          // nil = "não existe letra sincronizada" (cache negativo)
    var score: Double
    var needsReview: Bool
    var pinned: Bool                     // escolha manual do usuário: nunca sobrescrever
    var offlinePinned: Bool? = nil        // download explícito: manter letra além do TTL
    var alternatives: [LRCLIBRecord]     // top candidatos p/ "trocar letra" sem rede
    var savedAt: Date
}

struct LyricsDiskCache: Sendable {
    private let dir: URL
    private static let positiveTTL: TimeInterval = 90 * 86_400
    private static let negativeTTL: TimeInterval = 24 * 3_600      // letras novas aparecem no LRCLIB com o tempo

    init() {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        dir = base.appendingPathComponent("lyrics", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    func load(_ id: String) -> CachedLyricsChoice? {
        guard let data = try? Data(contentsOf: url(id)),
              let c = try? JSONDecoder().decode(CachedLyricsChoice.self, from: data) else { return nil }
        let age = Date().timeIntervalSince(c.savedAt)
        if c.pinned || c.offlinePinned == true { return c }
        return age < (c.selected == nil ? Self.negativeTTL : Self.positiveTTL) ? c : nil
    }

    func save(_ c: CachedLyricsChoice, id: String) {
        if let data = try? JSONEncoder().encode(c) { try? data.write(to: url(id), options: .atomic) }
    }

    private func url(_ id: String) -> URL {
        let safe = id.filter { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
        return dir.appendingPathComponent(safe + ".json")
    }
}

// MARK: - Prefetcher

/// Estratégia:
///  0. cache em disco (0 requisições)
///  1. GET /api/get com artista+título(+álbum)+duração  — 1 requisição, ±2 s de tolerância
///  2. se não houver candidato "confident": GET /api/search por campos
///  3. se ainda não: GET /api/search?q=  (último recurso)
/// Para cedo assim que um candidato passa de `confidentThreshold`. Máximo de 3 requisições por faixa.
actor LyricsPrefetcher {
    private let client = LRCLIBClient()
    private let cache = LyricsDiskCache()
    private let store: LyricsStore
    private var task: Task<Void, Never>?
    private var warmTask: Task<Void, Never>?
    private var activeID: String?
    private var warmedID: String?
    private var activeSourceURL: URL?
    private var activeDuration: TimeInterval = 0

    init(store: LyricsStore) { self.store = store }

    /// Chame quando a reprodução COMEÇA (não quando a aba/modo de letras abre).
    func start(_ meta: TrackMetadata, sourceURL: URL? = nil) async {
        // The player commits the source and resets LyricsStore synchronously.
        // A delayed launch from an older selection must never take ownership.
        guard await store.trackID == meta.videoID else { return }
        task?.cancel()
        warmTask?.cancel()
        activeID = meta.videoID
        activeSourceURL = sourceURL
        activeDuration = meta.duration ?? 0
        warmedID = nil
        task = Task(priority: .userInitiated) { [weak self] in await self?.run(meta, apply: true) }
    }

    /// Aquece o cache da próxima faixa da fila (ex.: quando a atual passa de 70%). Não toca no store.
    func warm(_ meta: TrackMetadata) {
        guard meta.videoID != activeID, meta.videoID != warmedID else { return }
        warmedID = meta.videoID
        warmTask = Task(priority: .background) { [weak self] in
            await self?.run(meta, apply: false)
        }
    }

    func cancel() {
        task?.cancel(); warmTask?.cancel()
        activeID = nil; warmedID = nil
        activeSourceURL = nil
    }

    /// A tela de letras consulta a seleção persistida sem chamar a rede.
    func cachedChoice(for videoID: String) -> CachedLyricsChoice? { cache.load(videoID) }

    /// Offline preparation never replaces the current Karaoke lyrics in LyricsStore.
    func ensureSyncedLyrics(_ meta: TrackMetadata) async -> Bool {
        if var cached = cache.load(meta.videoID),
           cached.selected?.syncedLyrics?.isEmpty == false {
            cached.offlinePinned = true
            cache.save(cached, id: meta.videoID)
            return true
        }
        await run(meta, apply: false)
        guard var choice = cache.load(meta.videoID),
              choice.selected?.syncedLyrics?.isEmpty == false else { return false }
        choice.offlinePinned = true
        cache.save(choice, id: meta.videoID)
        return true
    }

    /// A tela pode aguardar o trabalho já em curso, em vez de iniciar um segundo
    /// fluxo de até 3 requisições quando o usuário abre o karaokê rapidamente.
    func awaitChoice(for videoID: String) async -> CachedLyricsChoice? {
        if activeID == videoID { await task?.value }
        return cache.load(videoID)
    }

    /// Escolha manual ("trocar letra"): vira definitiva para esta faixa.
    func pin(_ record: LRCLIBRecord, for videoID: String) async {
        guard await store.trackID == videoID else { return }
        if activeID == videoID { task?.cancel() }
        var c = cache.load(videoID) ?? CachedLyricsChoice(selected: nil, score: 1, needsReview: false,
                                                           pinned: true, alternatives: [], savedAt: Date())
        c.selected = record; c.pinned = true; c.needsReview = false; c.score = 1; c.savedAt = Date()
        cache.save(c, id: videoID)
        if let lrc = record.syncedLyrics {
            await store.loadIfCurrent(trackID: videoID, rawLRC: lrc, needsReview: false, force: true)
        } else if let sourceURL = activeSourceURL {
            await store.loadFallback(trackID: videoID, plainText: record.plainLyrics,
                                     sourceURL: sourceURL, duration: activeDuration,
                                     force: true)
        }
    }

    func alternatives(for videoID: String) -> [LRCLIBRecord] { cache.load(videoID)?.alternatives ?? [] }

    // MARK: -

    private func run(_ m: TrackMetadata, apply: Bool) async {
        guard !Task.isCancelled, !apply || activeID == m.videoID else { return }

        if let cached = cache.load(m.videoID) { await finish(cached, m, apply); return }

        let q = LyricsQuery(m)
        var pool: [LRCLIBRecord] = []

        func confident() -> Bool { RankedLyricsMatcher.rank(q, pool).first?.verdict == .confident }

        // 1) match exato
        if let artist = q.artist, !Task.isCancelled,
           let r = try? await client.get(track: q.title, artist: q.firstArtist ?? artist,
                                         album: q.album, duration: q.duration) {
            pool.append(r)
        }
        // 2) busca por campos (artista só entra se for confiável)
        if !confident(), !Task.isCancelled,
           let rs = try? await client.search(track: q.title, artist: q.artistIsReliable ? q.firstArtist : nil) {
            pool.append(contentsOf: rs)
        }
        // 3) último recurso: busca livre, com título sem parênteses
        if !confident(), !Task.isCancelled {
            let free = [q.artistIsReliable ? q.firstArtist : nil, MetadataCleaner.simplified(q.title)]
                .compactMap { $0 }.joined(separator: " ")
            if let rs = try? await client.search(q: free) { pool.append(contentsOf: rs) }
        }
        if Task.isCancelled { return }

        let ranked = RankedLyricsMatcher.rank(q, pool)
        let eligible = ranked.filter { $0.verdict != .rejected }
        var choice = CachedLyricsChoice(selected: nil, score: 0, needsReview: false, pinned: false,
                                        alternatives: ranked.prefix(5).map(\.record), savedAt: Date())
        if let best = eligible.first {
            choice.selected = best.record
            choice.score = best.score
            choice.needsReview = best.verdict == .review
        }
        cache.save(choice, id: m.videoID)
        await finish(choice, m, apply)
    }

    private func finish(_ c: CachedLyricsChoice, _ m: TrackMetadata, _ apply: Bool) async {
        guard apply, !Task.isCancelled, activeID == m.videoID else { return }   // resultado velho de faixa anterior
        if let lrc = c.selected?.syncedLyrics {
            await store.loadIfCurrent(trackID: m.videoID, rawLRC: lrc,
                             needsReview: c.needsReview, force: c.pinned)
        } else if let sourceURL = activeSourceURL {
            await store.loadFallback(trackID: m.videoID,
                                     plainText: c.selected?.plainLyrics,
                                     sourceURL: sourceURL, duration: activeDuration)
        } else {
            await store.markUnavailable(trackID: m.videoID)
        }
    }
}
