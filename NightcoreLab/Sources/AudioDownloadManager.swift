import AVFoundation
import Combine
import DownloadKit
import Foundation

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
    @Published private(set) var cachedIDs = Set<String>()
    var backgroundCompletionHandler: (() -> Void)?

    private let transfers: DownloadKit.DownloadManager
    private var cache = TrackAudioCache()
    private var tracks: [UUID: Track] = [:]
    private var tasks: [UUID: URLSessionDownloadTask] = [:]
    private var attempts: [String: Int] = [:]
    private var selectedID: String?
    private var playingID: String?
    private var onReady: ((URL, URL?) -> Void)?
    private var lastWarmUp: Date?
    private var mutation: Task<Void, Never>?
    private var retryTask: Task<Void, Never>?
    private var selectionGeneration = UUID()

    init() {
        let configuration = URLSessionConfiguration.background(withIdentifier: Self.backgroundIdentifier)
        configuration.isDiscretionary = false
        configuration.sessionSendsLaunchEvents = true
        configuration.timeoutIntervalForRequest = 180
        configuration.timeoutIntervalForResource = 900
        configuration.httpMaximumConnectionsPerHost = 2
        transfers = DownloadKit.DownloadManager(sessionConfiguration: configuration)
        transfers.setDelegate(self)
        transfers.setMaxConcurrentDownloads(1)
        cachedIDs = Set(cache.entries.keys)
        serialize {
            await withCheckedContinuation { continuation in
                self.transfers.attachOutstandingDownloadTasks { _ in continuation.resume() }
            }
        }
    }

    func cachedTrack(_ track: Track) -> Track {
        var result = cache.entries[track.id]?.track ?? track
        result.isCached = cache.localURL(for: track.id) != nil
        return result
    }

    func downloadAudio(youtubeURL: String, onReady: @escaping (URL, URL?) -> Void) {
        guard let track = Track.from(url: youtubeURL) else {
            errorMessage = "Cole um link válido do YouTube."
            return
        }
        select(track, onReady: onReady)
    }

    func select(_ track: Track, onReady: @escaping (URL, URL?) -> Void) {
        retryTask?.cancel()
        selectionGeneration = UUID()
        let generation = selectionGeneration
        selectedID = track.id
        self.onReady = onReady
        errorMessage = nil
        isRetrying = false
        isDownloading = true
        downloadProgress = 0
        attempts[track.id] = 0
        let cachedLocal = cache.localURL(for: track.id)
        let cached = cachedTrack(track)
        serialize {
            guard generation == self.selectionGeneration else { return }
            // Stop queue advancement before removing speculative work. An already-running
            // download of the selected track is reused instead of being restarted.
            self.transfers.setMaxConcurrentDownloads(0)
            let obsolete = self.transfers.downloads.filter { self.tracks[$0.id]?.id != track.id }
            for item in obsolete {
                self.tracks[item.id] = nil
                self.tasks[item.id] = nil
                await self.transfers.remove(item)
            }
            self.transfers.setMaxConcurrentDownloads(1)
            guard generation == self.selectionGeneration else { return }
            if cachedLocal != nil {
                self.persistPending()
                return
            } else if let existing = self.transfers.downloads.first(where: { self.tracks[$0.id]?.id == track.id }) {
                self.tasks[existing.id]?.priority = URLSessionTask.highPriority
                self.downloadProgress = existing.fractionCompleted
                if existing.status != .downloading {
                    // Changing maxConcurrentDownloads alone does not drain the upstream queue.
                    self.tasks[existing.id]?.cancel()
                    existing.userInfo["priority"] = URLSessionTask.highPriority
                    await self.transfers.resume(existing)
                }
            } else {
                await self.append(track, priority: URLSessionTask.highPriority)
            }
            self.persistPending()
        }
        // Cache hits open immediately, before awaiting cancellation of speculative transfers.
        if let cachedLocal { deliver(cachedLocal, track: cached) }
    }

    /// Called only once the audio engine has actually started playback.
    func prefetch(_ upcoming: [Track], playing id: String) {
        guard selectedID == id else { return }
        playingID = id
        let generation = selectionGeneration
        let next = Self.nextTracks(upcoming, excluding: id)
        serialize {
            guard generation == self.selectionGeneration else { return }
            for track in next {
                guard generation == self.selectionGeneration else { return }
                guard self.cache.localURL(for: track.id) == nil,
                      !self.tracks.values.contains(where: { $0.id == track.id }) else { continue }
                await self.append(track, priority: URLSessionTask.lowPriority)
            }
            self.persistPending()
        }
    }

    nonisolated static func nextTracks(_ tracks: [Track], excluding id: String) -> [Track] {
        var seen = Set([id])
        return Array(tracks.filter { seen.insert($0.id).inserted }.prefix(5))
    }

    func cancel() {
        selectionGeneration = UUID()
        retryTask?.cancel()
        selectedID = nil
        onReady = nil
        isDownloading = false
        isRetrying = false
        downloadProgress = 0
        serialize {
            self.transfers.setMaxConcurrentDownloads(0)
            let downloads = self.transfers.downloads
            self.tracks.removeAll()
            self.tasks.removeAll()
            await self.transfers.remove(Set(downloads))
            self.transfers.setMaxConcurrentDownloads(1)
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

    private func append(_ track: Track, priority: Float) async {
        guard var endpoint = URLComponents(string: Self.apiBaseURL) else {
            fail(track, message: "Endereço do servidor inválido.")
            return
        }
        endpoint.path += "/download"
        endpoint.queryItems = [URLQueryItem(name: "url", value: track.url.absoluteString)]
        guard let url = endpoint.url else {
            fail(track, message: "Endereço do servidor inválido.")
            return
        }
        // GET is intentional: background download tasks must be reconstructible without a POST body.
        let request = URLRequest(url: url, timeoutInterval: 180)
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
        let callback = onReady
        onReady = nil
        callback?(local, track.thumbnailURL)
    }

    private func fail(_ track: Track, message: String) {
        guard selectedID == track.id, onReady != nil else { return }
        isDownloading = false
        isRetrying = false
        errorMessage = message
        onReady = nil
    }

    private var pendingURL: URL { cache.folder.appendingPathComponent("pending.json") }

    private func persistPending() {
        try? FileManager.default.createDirectory(at: cache.folder, withIntermediateDirectories: true)
        let unique = Dictionary(tracks.values.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        if let data = try? JSONEncoder().encode(unique) { try? data.write(to: pendingURL, options: .atomic) }
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
            }.prefix(10))
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
        guard let url = URL(string: Self.apiBaseURL) else { return }
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
                return (false, "O endereço respondeu (\(http.statusCode)), mas não é o servidor do Nightcore Lab.")
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
        let pending = (try? Data(contentsOf: pendingURL))
            .flatMap { try? JSONDecoder().decode([String: Track].self, from: $0) }
        tracks[download.id] = pending?[fallback.id] ?? fallback
    }

    func download(_ download: Download, didFinishDownloadingTo location: URL) async {
        guard var track = tracks[download.id] else { return }
        if let response = tasks[download.id]?.response as? HTTPURLResponse {
            let title = response.suggestedFilename.map { ($0 as NSString).deletingPathExtension }
            let cover = response.value(forHTTPHeaderField: "X-Cover-Url").flatMap(URL.init(string:))
            track = Track(id: track.id, title: title ?? track.title,
                          thumbnailURL: cover?.scheme == "https" ? cover : track.thumbnailURL)
        }
        do {
            let local = try cache.store(track, from: location)
            var protected = Set(tracks.values.map(\.id))
            if let playingID { protected.insert(playingID) }
            if let selectedID { protected.insert(selectedID) }
            cache.trim(protecting: protected)
            cachedIDs = Set(cache.entries.keys)
            deliver(local, track: track)
        } catch {
            fail(track, message: "Não foi possível salvar o áudio: \(error.localizedDescription)")
        }
        tracks[download.id] = nil
        tasks[download.id] = nil
        persistPending()
        serialize { await self.transfers.remove(download) }
    }

    func downloadStatusDidChange(_ download: Download) async {
        guard case .failed(let error) = download.status, let track = tracks[download.id] else { return }
        tracks[download.id] = nil
        tasks[download.id] = nil
        serialize { await self.transfers.remove(download); self.persistPending() }
        // Speculative failures stay silent and can be retried on explicit selection.
        guard selectedID == track.id, onReady != nil else { return }
        let attempt = (attempts[track.id] ?? 0) + 1
        attempts[track.id] = attempt
        let retryable: Bool
        switch error {
        case .serverError(let status): retryable = [429, 502, 503, 504].contains(status)
        case .transportError: retryable = true
        default: retryable = false
        }
        guard retryable, attempt < 3 else {
            fail(track, message: "Não foi possível baixar o áudio. Verifique o servidor e tente novamente.")
            return
        }
        isRetrying = true
        let generation = selectionGeneration
        retryTask = Task { @MainActor in
            do { try await Task.sleep(for: .seconds(attempt * 3)) } catch { return }
            guard generation == self.selectionGeneration else { return }
            self.serialize {
                guard generation == self.selectionGeneration else { return }
                await self.append(track, priority: URLSessionTask.highPriority)
            }
        }
    }

    func downloadDidUpdateProgress(_ download: Download) async {
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
