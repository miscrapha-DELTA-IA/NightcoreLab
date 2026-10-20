import AVFoundation
import Combine
import DownloadKit
import Foundation
import UIKit

/// Main-actor coordinator; DownloadKit owns URLSession tasks and its serial transfer queue.
@MainActor
final class AudioDownloadManager: ObservableObject {
    static let shared = AudioDownloadManager()
    static let backgroundIdentifier = "com.nightcorelab.audio-downloads.v1"
    static let defaultServerURL = "https://nightcorelab.onrender.com"
    static let serverURLKey = "serverURL"
    static var apiBaseURL: String {
        normalizedServerURL(UserDefaults.standard.string(forKey: serverURLKey) ?? defaultServerURL)
    }

    @Published private(set) var isDownloading = false
    @Published var errorMessage: String?
    @Published private(set) var relatedErrorMessage: String?
    @Published private(set) var downloadProgress: Double = 0
    @Published private(set) var isRetrying = false
    @Published private(set) var isRateLimited = false
    private var rateLimitUntil: Date = .distantPast
    private var breakerTask: Task<Void, Never>?
    @Published private(set) var cachedIDs = Set<String>()
    @Published private(set) var downloadingIDs = Set<String>()
    @Published private(set) var offlineDownloadProgress: [String: Double] = [:]
    var backgroundCompletionHandler: (() -> Void)?

    private let transfers: DownloadKit.DownloadManager
    private var cache = TrackAudioCache(loadIndex: false)
    private let cacheIO = AudioCacheIO()
    private var lastProgressUpdate: [UUID: Date] = [:]
    private var memoryWarningObserver: NSObjectProtocol?
    private var tracks: [UUID: Track] = [:]
    private var offlineWaiters: [String: [CheckedContinuation<URL, Error>]] = [:]
    private var tasks: [UUID: URLSessionDownloadTask] = [:]
    private var attempts: [String: Int] = [:]
    private var selectedID: String?
    private var playingID: String?
    private var onReady: ((URL, URL?) -> Void)?
    private var onFailure: ((String) -> Void)?
    private var lastWarmUp: Date?
    private var mutation: Task<Void, Never>?
    private var retryTask: Task<Void, Never>?
    private var offlineRetries: [String: Task<Void, Never>] = [:]
    private var selectionGeneration = UUID()
    private var offlineQueue: [Track] = []
    private var preparations: [String: Task<Void, Never>] = [:]
    private var preparationPriorities: [String: Float] = [:]
    private var preparationGenerations: [String: UUID] = [:]

    func canRemoveOfflineAudio(_ track: Track) -> Bool {
        track.id != selectedID && track.id != playingID
    }

    func removeOfflineAudio(_ track: Track) {
        guard canRemoveOfflineAudio(track) else { return }
        updateCache { try? $0.remove(track.id) }
    }

    func cancelOfflineAudio(_ track: Track) {
        offlineQueue.removeAll { $0.id == track.id }
        offlineRetries.removeValue(forKey: track.id)?.cancel()
        completeOfflineAudio(track.id, result: .failure(URLError(.cancelled)))
        // A playback request sharing this transfer keeps its own ownership.
        guard selectedID != track.id else { return }
        let cancelled = transfers.downloads.filter { tracks[$0.id]?.id == track.id }
        serialize {
            for download in cancelled {
                self.tracks[download.id] = nil
                self.tasks[download.id] = nil
                await self.transfers.remove(download)
            }
            self.persistPending()
            self.startNextOffline()
        }
    }

    init(configuration customConfiguration: URLSessionConfiguration? = nil) {
        let configuration = customConfiguration ?? URLSessionConfiguration.background(withIdentifier: Self.backgroundIdentifier)
        configuration.isDiscretionary = false
        if customConfiguration == nil { configuration.sessionSendsLaunchEvents = true }
        configuration.timeoutIntervalForRequest = 180
        configuration.timeoutIntervalForResource = 900
        configuration.httpMaximumConnectionsPerHost = 2
        transfers = DownloadKit.DownloadManager(sessionConfiguration: configuration)
        transfers.setDelegate(self)
        // Foreground selection + one background prefetch at a time.
        transfers.setMaxConcurrentDownloads(2)
        Task {
            if let (_, loaded) = try? await cacheIO.perform({ _ in () }) {
                cache = loaded
                cachedIDs = Set(loaded.entries.keys)
            }
        }
        memoryWarningObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.handleMemoryPressure()
                }
            }
        serialize {
            await withCheckedContinuation { continuation in
                self.transfers.attachOutstandingDownloadTasks { _ in continuation.resume() }
            }
        }
    }

    /// Called outside CoreAudio callbacks. No changes to the current source,
    /// active downloads, pad voice pool or uncommitted transfer files.
    func handleMemoryPressure() {
        var protected = Set(tracks.values.map(\.id))
        if let playingID { protected.insert(playingID) }
        if let selectedID { protected.insert(selectedID) }
        updateCache { $0.evictUnprotected(protecting: protected) }
    }

    func cachedTrack(_ track: Track) -> Track {
        var result = cache.entries[track.id]?.track ?? track
        // Metadata YT Music não pode ser perdido quando o arquivo já existe em cache.
        result.cleanArtist = track.cleanArtist ?? result.cleanArtist
        result.cleanTitle = track.cleanTitle ?? result.cleanTitle
        result.album = track.album ?? result.album
        result.duration = track.duration ?? result.duration
        result.isCached = cache.indexedURL(for: track.id) != nil
        return result
    }

    var quickLibraryTracks: [Track] {
        cache.entries.values.sorted { $0.accessedAt > $1.accessedAt }
            .prefix(8).map { cachedTrack($0.track) }
    }

    var offlineCacheBadge: String { cache.cacheBadge }

    var allCachedTracks: [Track] {
        cache.entries.values.sorted { $0.accessedAt > $1.accessedAt }
            .map { cachedTrack($0.track) }
    }

    /// Background save joins an existing transfer and never changes playback selection.
    func saveOfflineAudio(_ track: Track) async throws -> URL {
        if let local = cache.indexedURL(for: track.id) {
            updateCache { $0.pin(track.id) }
            return local
        }
        return try await withCheckedThrowingContinuation { continuation in
            offlineWaiters[track.id, default: []].append(continuation)
            offlineDownloadProgress[track.id] = 0
            serialize {
                if let local = self.cache.indexedURL(for: track.id) {
                    self.completeOfflineAudio(track.id, result: .success(local))
                    return
                }
                guard !self.tracks.values.contains(where: { $0.id == track.id }) else { return }
                guard !self.offlineQueue.contains(where: { $0.id == track.id }) else { return }
                self.offlineQueue.append(track)
                self.refreshTrackStatuses()
                self.startNextOffline()
            }
        }
    }

    private func completeOfflineAudio(_ id: String, result: Result<URL, Error>) {
        if case .success = result { updateCache { $0.pin(id) } }
        offlineDownloadProgress[id] = nil
        offlineRetries[id] = nil
        for waiter in offlineWaiters.removeValue(forKey: id) ?? [] {
            waiter.resume(with: result)
        }
    }

    func status(for track: Track) -> TrackStatus {
        TrackStatus.resolve(cached: cachedIDs.contains(track.id),
                            downloading: downloadingIDs.contains(track.id))
    }

    /// Never calls the backend. Returns nil after local eviction/reinstall.
    func cachedAudioURL(for track: Track) -> URL? {
        cache.indexedURL(for: track.id)
    }

    func saveLastTrack(_ track: Track, at position: TimeInterval = 0) {
        PlaybackSessionStorage.save(track, at: position)
    }

    func loadLastTrack() -> SavedPlaybackSession? {
        PlaybackSessionStorage.load()
    }

    func clearLastTrack() {
        PlaybackSessionStorage.clear()
    }

    private func refreshTrackStatuses() {
        var pending = Set(tracks.values.map(\.id) + offlineQueue.map(\.id) + Array(preparations.keys))
        if isDownloading, let selectedID {
            pending.insert(selectedID)
        }
        pending.subtract(cachedIDs)
        if pending != downloadingIDs {
            downloadingIDs = pending
        }
    }

    func downloadAudio(youtubeURL: String, onReady: @escaping (URL, URL?) -> Void) {
        guard let track = Track.from(url: youtubeURL) else {
            errorMessage = "Cole um link válido do YouTube."
            return
        }
        select(track, onReady: onReady)
    }

    func select(_ track: Track, onReady: @escaping (URL, URL?) -> Void,
                onFailure: ((String) -> Void)? = nil) {
        retryTask?.cancel()
        selectionGeneration = UUID()
        let generation = selectionGeneration
        selectedID = track.id
        self.onReady = onReady
        self.onFailure = onFailure
        errorMessage = nil
        isRetrying = false
        let cachedLocal = cache.indexedURL(for: track.id)
        isDownloading = cachedLocal == nil
        downloadProgress = cachedLocal == nil ? 0 : 1
        attempts[track.id] = 0
        refreshTrackStatuses()
        let cached = cachedTrack(track)
        if let cachedLocal {
            // Local playback is immediate and does not invalidate in-flight Up Next work.
            deliver(cachedLocal, track: cached)
            return
        }
        serialize {
            guard generation == self.selectionGeneration else { return }
            self.offlineQueue.removeAll { $0.id == track.id }
            // Never remove speculative transfers on a manual playback selection:
            // reuse the matching DownloadKit task and promote its priority.
            if let local = self.cache.indexedURL(for: track.id) {
                self.deliver(local, track: self.cachedTrack(track))
            } else if let existing = self.transfers.downloads.first(where: { self.tracks[$0.id]?.id == track.id }) {
                existing.userInfo["priority"] = URLSessionTask.highPriority
                self.tasks[existing.id]?.priority = URLSessionTask.highPriority
                self.downloadProgress = existing.fractionCompleted
                switch existing.status {
                case .idle, .downloading, .finished:
                    break // Never restart an in-flight or completing transfer.
                case .paused, .failed:
                    await self.transfers.resume(existing)
                }
            } else {
                self.prepareDownload(track, priority: URLSessionTask.highPriority)
            }
            self.persistPending()
        }
    }

    /// Called only once the audio engine has actually started playback.
    func prefetch(_ upcoming: [Track], playing id: String) {
        guard selectedID == id else { return }
        playingID = id
        // Stage 42: no speculative network downloads. Explicit play/offline only.
    }

    nonisolated static func nextTracks(_ tracks: [Track], excluding id: String) -> [Track] {
        var seen = Set([id])
        return Array(tracks.filter { seen.insert($0.id).inserted }.prefix(3))
    }

    private func activateRateLimit(retryAfter: TimeInterval = 60) {
        isRateLimited = true
        rateLimitUntil = max(rateLimitUntil, Date().addingTimeInterval(max(60, retryAfter)))
        breakerTask?.cancel()
        breakerTask = Task { @MainActor in
            let wait = max(0, rateLimitUntil.timeIntervalSinceNow)
            try? await Task.sleep(for: .seconds(wait))
            guard !Task.isCancelled, Date() >= rateLimitUntil else { return }
            isRateLimited = false
            startNextOffline()
        }
        // Explicit offline transfers retain their waiters; no speculative tasks exist.
    }

    func cancelPlaybackSelection() {
        selectionGeneration = UUID()
        retryTask?.cancel()
        selectedID = nil; playingID = nil
        onReady = nil; onFailure = nil
        isDownloading = false; isRetrying = false; downloadProgress = 0
        refreshTrackStatuses()
        startNextOffline()
    }

    func cancel() {
        selectionGeneration = UUID()
        let generation = selectionGeneration
        retryTask?.cancel()
        preparations.values.forEach { $0.cancel() }
        preparations.removeAll(); preparationPriorities.removeAll(); preparationGenerations.removeAll(); offlineQueue.removeAll()
        offlineRetries.values.forEach { $0.cancel() }
        offlineRetries.removeAll()
        for id in Array(offlineWaiters.keys) { completeOfflineAudio(id, result: .failure(URLError(.cancelled))) }
        selectedID = nil
        onReady = nil
        onFailure = nil
        isDownloading = false
        isRetrying = false
        downloadProgress = 0
        refreshTrackStatuses()
        serialize {
            // A new track may have been selected while this cancellation waited
            // for older queue mutations. Never erase its download.
            guard generation == self.selectionGeneration else { return }
            self.transfers.setMaxConcurrentDownloads(0)
            let downloads = self.transfers.downloads
            self.tracks.removeAll()
            self.tasks.removeAll()
            await self.transfers.remove(Set(downloads))
            self.transfers.setMaxConcurrentDownloads(2)
            self.persistPending()
        }
    }

    private func serialize(_ operation: @escaping @MainActor () async -> Void) {
        let previous = mutation
        mutation = Task { @MainActor in
            await previous?.value
            await operation()
        }
    }

    private func startNextOffline() {
        guard !isDownloading, !isRateLimited, preparations.isEmpty,
              tracks.isEmpty, !offlineQueue.isEmpty else { return }
        let track = offlineQueue.removeFirst()
        prepareDownload(track, priority: URLSessionTask.defaultPriority)
    }

    /// Resolve catalog metadata outside the serial transfer-mutation queue.
    /// Saving a Mix can no longer block a playback selection behind 15 lookups.
    private func prepareDownload(_ sourceTrack: Track, priority: Float) {
        preparationPriorities[sourceTrack.id] = max(priority, preparationPriorities[sourceTrack.id] ?? priority)
        guard preparations[sourceTrack.id] == nil else { return }
        let generation = UUID()
        preparationGenerations[sourceTrack.id] = generation
        preparations[sourceTrack.id] = Task { @MainActor in
            do {
                let track = try await MusicCatalogService.shared.playable(sourceTrack, baseURL: Self.apiBaseURL)
                try Task.checkCancellation()
                guard preparationGenerations[track.id] == generation else { return }
                let requestedPriority = preparationPriorities.removeValue(forKey: track.id) ?? priority
                preparations[track.id] = nil
                serialize {
                    guard self.preparationGenerations[track.id] == generation else { return }
                    self.preparationGenerations[track.id] = nil
                    guard self.selectedID == track.id || self.offlineWaiters[track.id] != nil else {
                        self.startNextOffline()
                        return
                    }
                    if let local = self.cache.indexedURL(for: track.id) {
                        self.completeOfflineAudio(track.id, result: .success(local))
                        self.deliver(local, track: track)
                    } else if let existing = self.transfers.downloads.first(where: { self.tracks[$0.id]?.id == track.id }) {
                        self.tasks[existing.id]?.priority = max(requestedPriority, self.tasks[existing.id]?.priority ?? 0)
                    } else {
                        await self.appendPrepared(track, priority: requestedPriority)
                    }
                    self.persistPending()
                }
            } catch {
                guard preparationGenerations[sourceTrack.id] == generation else { return }
                preparationGenerations[sourceTrack.id] = nil
                preparations[sourceTrack.id] = nil
                preparationPriorities[sourceTrack.id] = nil
                completeOfflineAudio(sourceTrack.id, result: .failure(error))
                fail(sourceTrack, message: DownloadFailureMessage.describe(error))
                startNextOffline()
            }
        }
        refreshTrackStatuses()
    }

    private func appendPrepared(_ track: Track, priority: Float) async {
        guard var endpoint = URLComponents(string: Self.apiBaseURL) else {
            completeOfflineAudio(track.id, result: .failure(URLError(.badURL)))
            fail(track, message: "Endereço do servidor inválido.")
            return
        }
        endpoint.path += "/download"
        endpoint.queryItems = [URLQueryItem(name: "url", value: track.url.absoluteString)]
        guard let url = endpoint.url else {
            completeOfflineAudio(track.id, result: .failure(URLError(.badURL)))
            fail(track, message: "Endereço do servidor inválido.")
            return
        }
        // GET is intentional: background download tasks must be reconstructible without a POST body.
        let request = URLRequest(url: url, timeoutInterval: 180)
        guard priority != URLSessionTask.lowPriority || !isRateLimited else { return }
        let download = Download(request: request)
        tracks[download.id] = track
        download.userInfo["priority"] = priority
        persistPending()
        await transfers.append(download)
    }

    private func deliver(_ local: URL, track: Track) {
        guard selectedID == track.id else { return }
        isDownloading = false
        isRetrying = false
        downloadProgress = 1
        refreshTrackStatuses()
        let callback = onReady
        onReady = nil
        onFailure = nil
        callback?(local, track.thumbnailURL)
        startNextOffline()
    }

    private func fail(_ track: Track, message: String) {
        guard selectedID == track.id, onReady != nil else { return }
        isDownloading = false
        isRetrying = false
        errorMessage = message
        refreshTrackStatuses()
        let callback = onFailure
        onReady = nil
        onFailure = nil
        callback?(message)
        startNextOffline()
    }

    private var pendingURL: URL { cache.folder.appendingPathComponent("pending.json") }

    private func persistPending() {
        refreshTrackStatuses()
        let unique = Dictionary(tracks.values.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let destination = pendingURL
        updateCache { cache in
            try? FileManager.default.createDirectory(at: cache.folder, withIntermediateDirectories: true)
            if let data = try? JSONEncoder().encode(unique) { try? data.write(to: destination, options: .atomic) }
        }
    }

    private func updateCache(_ operation: @escaping (inout TrackAudioCache) -> Void) {
        Task {
            if let (_, updated) = try? await cacheIO.perform(operation) {
                cache = updated
                cachedIDs = Set(updated.entries.keys)
            }
        }
    }

    func fetchRelatedVideos(for url: String) async -> [Track] {
        relatedErrorMessage = nil
        guard let source = Self.youtubeVideoURL(from: url),
              var components = URLComponents(string: Self.apiBaseURL) else {
            relatedErrorMessage = "Não foi possível consultar sugestões para este link."
            return []
        }
        components.path += "/related"
        components.queryItems = [URLQueryItem(name: "url", value: source.absoluteString)]
        guard let endpoint = components.url else { return [] }
        var request = URLRequest(url: endpoint, timeoutInterval: 25)
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            try Task.checkCancellation()
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                relatedErrorMessage = "Sugestões indisponíveis agora. Tente novamente."
                return []
            }
            let videos = try JSONDecoder().decode([RelatedVideo].self, from: data)
            var seen = Set([source.absoluteString])
            return Array(videos.compactMap { video -> Track? in
                guard let canonical = Self.youtubeVideoURL(from: video.url.absoluteString),
                      !video.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      seen.insert(canonical.absoluteString).inserted else { return nil }
                let thumbnail = video.thumbnail?.scheme?.lowercased() == "https" ? video.thumbnail : nil
                return Track(id: canonical.query!.replacingOccurrences(of: "v=", with: ""), title: video.title, thumbnailURL: thumbnail)
            }.prefix(30))
        } catch {
            if !Task.isCancelled {
                relatedErrorMessage = "Não foi possível carregar as sugestões."
            }
            return []
        }
    }

    /// Acorda o servidor do Render em segundo plano (GET /), no máximo uma vez por minuto.
    /// Chamado quando o app abre e quando o usuário toca no campo de link, para que o
    /// cold start aconteça enquanto ele ainda está colando o endereço.
    func warmUp() {
        if let lastWarmUp, Date().timeIntervalSince(lastWarmUp) < 60 { return }
        guard let url = URL(string: Self.apiBaseURL + "/warm") else { return }
        lastWarmUp = Date()

        var request = URLRequest(url: url, timeoutInterval: 90)
        request.httpMethod = "GET"
        URLSession.shared.dataTask(with: request).resume()
    }

    /// Testa o servidor (tela de configurações). Devolve uma mensagem pronta para exibir.
    func checkServer(_ address: String) async -> (ok: Bool, message: String) {
        guard let url = URL(string: Self.normalizedServerURL(address)) else {
            return (false, "Endereço inválido.")
        }
        var request = URLRequest(url: url, timeoutInterval: 90)
        request.httpMethod = "GET"

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else { return (false, "Resposta inválida.") }
            guard http.statusCode == 200,
                  let health = try? JSONDecoder().decode(HealthResponse.self, from: data),
                  health.status == "ok" else {
                return (false, "O endereço respondeu (\(http.statusCode)), mas não é o servidor do Gnarly.")
            }
            let ffmpeg = health.ffmpeg == true ? "com FFmpeg" : "sem FFmpeg"
            let version = health.ytdlp.map { " · yt-dlp \($0)" } ?? ""
            return (true, "Servidor online (\(ffmpeg)\(version)).")
        } catch let error as URLError where error.code == .timedOut {
            return (false, "Sem resposta. Se for o Render gratuito, tente de novo em alguns segundos.")
        } catch {
            return (false, error.localizedDescription)
        }
    }

    /// Aceita "nightcorelab.onrender.com", "https://…/", espaços etc.
    nonisolated static func normalizedServerURL(_ raw: String) -> String {
        var address = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        while address.hasSuffix("/") { address.removeLast() }
        if !address.isEmpty, !address.contains("://") {
            address = "https://" + address
        }
        return address
    }


    nonisolated static func looksLikeYouTube(_ link: String) -> Bool {
        youtubeVideoURL(from: link) != nil
    }

    nonisolated static func youtubeVideoURL(from raw: String) -> URL? {
        guard let parts = URLComponents(string: raw.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = parts.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = parts.host?.lowercased(),
              ["youtube.com", "www.youtube.com", "m.youtube.com", "music.youtube.com", "youtu.be"].contains(host),
              parts.user == nil, parts.password == nil,
              parts.port == nil || parts.port == 80 || parts.port == 443 else { return nil }
        let path = parts.path.split(separator: "/").map(String.init)
        let videoID: String?
        if host == "youtu.be", path.count == 1 {
            videoID = path[0]
        } else if path == ["watch"] {
            videoID = parts.queryItems?.first(where: { $0.name == "v" })?.value
        } else if path.count == 2, ["shorts", "live", "embed"].contains(path[0]) {
            videoID = path[1]
        } else {
            videoID = nil
        }
        guard let videoID, videoID.range(of: "^[A-Za-z0-9_-]{11}$", options: .regularExpression) != nil else {
            return nil
        }
        return URL(string: "https://www.youtube.com/watch?v=\(videoID)")
    }

    nonisolated static func youtubeURL(fromDeepLink url: URL) -> URL? {
        guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              parts.scheme?.lowercased() == "nightcore",
              parts.host?.lowercased() == "download",
              parts.path.isEmpty || parts.path == "/",
              parts.user == nil, parts.password == nil, parts.port == nil else { return nil }
        let links = parts.queryItems?.filter { $0.name == "link" } ?? []
        guard links.count == 1, let link = links.first?.value else { return nil }
        return youtubeVideoURL(from: link)
    }
}

private struct HealthResponse: Decodable {
    let status: String
    let ffmpeg: Bool?
    let ytdlp: String?

    enum CodingKeys: String, CodingKey {
        case status, ffmpeg
        case ytdlp = "yt_dlp"
    }
}


extension AudioDownloadManager: DownloadManagerDelegate {
    func download(_ download: Download, didCreateTask task: URLSessionDownloadTask) async {
        tasks[download.id] = task
        task.priority = download.userInfo["priority"] as? Float ?? URLSessionTask.lowPriority
    }

    func download(_ download: Download, didReconnectTask task: URLSessionDownloadTask) async {
        // This pinned upstream revision rebuilds tasks on attach. Cancel the original
        // explicitly to avoid leaving a second transfer running without a delegate mapping.
        task.cancel()
        guard let source = URLComponents(url: download.url, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == "url" })?.value,
              let fallback = Track.from(url: source) else { return }
        let destination = pendingURL
        let restored = try? await cacheIO.perform { _ in
            (try? Data(contentsOf: destination))
                .flatMap { try? JSONDecoder().decode([String: Track].self, from: $0) }
        }
        let pending = restored?.0
        tracks[download.id] = pending?.values.first(where: { $0.url == fallback.url }) ?? fallback
    }

    func download(_ download: Download, didFinishDownloadingTo location: URL) async {
        guard var track = tracks[download.id] else { return }
        if let response = tasks[download.id]?.response as? HTTPURLResponse {
            let title = response.suggestedFilename.map { ($0 as NSString).deletingPathExtension }
            let cover = response.value(forHTTPHeaderField: "X-Cover-Url").flatMap(URL.init(string:))
            track = Track(id: track.id, title: title ?? track.title,
                          thumbnailURL: cover?.scheme == "https" ? cover : track.thumbnailURL,
                          cleanArtist: track.cleanArtist, cleanTitle: track.cleanTitle,
                          album: track.album, duration: track.duration, trackNumber: track.trackNumber,
                          catalogProvider: track.catalogProvider, collectionID: track.collectionID,
                          artistID: track.artistID, streamVideoID: track.streamVideoID)
        }
        do {
            var protected = Set(tracks.values.map(\.id))
            if let playingID { protected.insert(playingID) }
            if let selectedID { protected.insert(selectedID) }
            let completedTrack = track
            let shouldPin = offlineWaiters[track.id] != nil
            let (local, updated) = try await cacheIO.perform { cache in
                let local = try cache.store(completedTrack, from: location)
                if shouldPin { cache.pin(completedTrack.id) }
                cache.trim(protecting: protected)
                return local
            }
            cache = updated
            cachedIDs = Set(cache.entries.keys)
            completeOfflineAudio(track.id, result: .success(local))
            deliver(local, track: track)
        } catch {
            completeOfflineAudio(track.id, result: .failure(error))
            fail(track, message: DownloadFailureMessage.describe(error))
        }
        tracks[download.id] = nil
        tasks[download.id] = nil
        lastProgressUpdate[download.id] = nil
        persistPending()
        serialize { await self.transfers.remove(download); self.startNextOffline() }
    }

    func downloadStatusDidChange(_ download: Download) async {
        guard case .failed(let error) = download.status, let track = tracks[download.id] else { return }
        let response = tasks[download.id]?.response as? HTTPURLResponse
        let rateLimited: Bool
        if case .serverError(let status) = error {
            rateLimited = status == 429
        } else {
            rateLimited = response?.statusCode == 429
        }
        let retryAfter = response?.value(forHTTPHeaderField: "Retry-After")
            .flatMap(TimeInterval.init) ?? 60
        tracks[download.id] = nil
        tasks[download.id] = nil
        lastProgressUpdate[download.id] = nil
        serialize { await self.transfers.remove(download); self.persistPending(); self.startNextOffline() }
        if rateLimited { activateRateLimit(retryAfter: retryAfter) }
        // Speculative failures stay silent and can be retried on explicit selection.
        guard (selectedID == track.id && onReady != nil) || offlineWaiters[track.id] != nil else { return }
        let attempt = (attempts[track.id] ?? 0) + 1
        attempts[track.id] = attempt
        let retryable: Bool
        switch error {
        case .serverError(let status): retryable = [429, 502, 503, 504].contains(status)
        case .transportError(let network, _):
            retryable = [.timedOut, .networkConnectionLost, .cannotConnectToHost,
                         .notConnectedToInternet, .dnsLookupFailed].contains(network.code)
        default: retryable = false
        }
        guard retryable, attempt < 2 else {
            completeOfflineAudio(track.id, result: .failure(error))
            fail(track, message: DownloadFailureMessage.describe(error, status: response?.statusCode))
            return
        }
        isRetrying = true
        let generation = selectionGeneration
        let retry = Task { @MainActor in
            let delay = rateLimited ? max(60, self.rateLimitUntil.timeIntervalSinceNow) : Double(3 * (1 << (attempt - 1)))
            do { try await Task.sleep(for: .seconds(delay)) } catch { return }
            guard generation == self.selectionGeneration || self.offlineWaiters[track.id] != nil else { return }
            self.serialize {
                guard generation == self.selectionGeneration || self.offlineWaiters[track.id] != nil else { return }
                self.prepareDownload(track, priority: URLSessionTask.highPriority)
            }
        }
        if offlineWaiters[track.id] != nil { offlineRetries[track.id] = retry }
        else { retryTask = retry }
    }

    func downloadDidUpdateProgress(_ download: Download) async {
        let now = Date()
        guard now.timeIntervalSince(lastProgressUpdate[download.id] ?? .distantPast) >= 0.25 else { return }
        lastProgressUpdate[download.id] = now
        if let id = tracks[download.id]?.id, offlineWaiters[id] != nil {
            offlineDownloadProgress[id] = download.fractionCompleted
        }
        guard tracks[download.id]?.id == selectedID else { return }
        downloadProgress = download.fractionCompleted
    }
    func downloadManagerDidFinishBackgroundDownloads() async {
        let completion = backgroundCompletionHandler
        backgroundCompletionHandler = nil
        completion?()
    }
    func download(_ download: Download, didCancelWithResumeData resumeData: Data?) async {}
    func resumeDataForDownload(_ download: Download) async -> Data? { nil }
    func downloadQueueDidChange(_ downloads: [Download]) async {}
    func downloadThroughputDidChange(_ bytesPerSecond: Int) async {}
}

enum DownloadFailureMessage {
    static func describe(_ error: Error, status: Int? = nil) -> String {
        if let status, status >= 400 {
            if status == 429 { return "Servidor ocupado (HTTP 429). Aguarde um minuto e tente novamente." }
            return "O servidor recusou o áudio (HTTP \(status)). Tente novamente ou escolha outra versão."
        }
        if let transfer = error as? DownloadError {
            switch transfer {
            case .serverError(let status): return describe(URLError(.badServerResponse), status: status)
            case .transportError(let network, _): return describe(network)
            default: break
            }
        }
        let ns = error as NSError
        if let underlying = ns.userInfo[NSUnderlyingErrorKey] as? Error {
            return describe(underlying)
        }
        if let url = error as? URLError {
            switch url.code {
            case .notConnectedToInternet: return "Sem conexão. Confira o Wi-Fi ou os dados móveis."
            case .timedOut: return "O servidor demorou a responder. Tente novamente."
            case .cancelled: return "Download cancelado."
            default: return "A conexão foi interrompida. Tente novamente."
            }
        }
        return "Não foi possível obter um arquivo de áudio válido. Tente outra versão ou confira o servidor."
    }
}
