import Foundation

/// Consome o microserviço FastAPI: POST /download {"url": ...} → .m4a em streaming.
@MainActor
final class DownloadManager: ObservableObject {

    // MARK: Configuração

    /// Servidor padrão. O usuário pode trocar dentro do app (tela "Servidor"),
    /// e o valor fica salvo no iPhone, sem precisar recompilar.
    static let defaultServerURL = "https://nightcorelab.onrender.com"
    static let serverURLKey = "serverURL"

    /// Generoso de propósito: cold start do Render (~50 s) + extração do yt-dlp no servidor.
    private static let requestTimeout: TimeInterval = 180
    /// Respostas típicas do Render enquanto o serviço acorda ou reinicia.
    private static let retryableStatusCodes: Set<Int> = [502, 503, 504]
    private static let maxAttempts = 2

    /// Pasta própria dos downloads: é esvaziada a cada novo download, então só existe
    /// um arquivo baixado por vez no cache.
    nonisolated private static let downloadsFolder = FileManager.default.temporaryDirectory
        .appendingPathComponent("youtube", isDirectory: true)

    /// Endereço atual (salvo pelo usuário ou o padrão), já normalizado.
    static var apiBaseURL: String {
        normalizedServerURL(UserDefaults.standard.string(forKey: serverURLKey) ?? defaultServerURL)
    }

    // MARK: Estado

    @Published private(set) var isDownloading = false
    @Published var errorMessage: String?
    /// 0 enquanto o servidor ainda extrai o áudio; de 0 a 1 durante a transferência.
    @Published private(set) var downloadProgress: Double = 0
    /// true durante a nova tentativa automática (servidor acordando).
    @Published private(set) var isRetrying = false

    private var task: URLSessionDownloadTask?
    private var progressObservation: NSKeyValueObservation?
    private var lastWarmUp: Date?

    // MARK: API pública

    /// Baixa o áudio do link e, em caso de sucesso, chama `onReady` na main thread
    /// com a URL local do .m4a, pronta para `AudioEngineManager.load(url:)`.
    func downloadAudio(youtubeURL: String, onReady: @escaping (URL) -> Void) {
        let link = youtubeURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !isDownloading else { return }

        guard Self.looksLikeYouTube(link) else {
            errorMessage = "Cole um link válido do YouTube."
            return
        }
        guard let endpoint = URL(string: Self.apiBaseURL)?.appendingPathComponent("download") else {
            errorMessage = "Endereço do servidor inválido. Confira em Servidor."
            return
        }

        var request = URLRequest(url: endpoint, timeoutInterval: Self.requestTimeout)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONEncoder().encode(["url": link])

        isDownloading = true
        isRetrying = false
        errorMessage = nil
        downloadProgress = 0
        start(request, attempt: 1, onReady: onReady)
    }

    func cancel() {
        task?.cancel()
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

    // MARK: Privado

    private func start(_ request: URLRequest, attempt: Int, onReady: @escaping (URL) -> Void) {
        let task = URLSession.shared.downloadTask(with: request) { [weak self] tempURL, response, error in
            // Fila de background. O arquivo temporário é apagado pelo sistema assim que
            // este bloco retorna, então ele precisa ser movido aqui, de forma síncrona.
            let result = Self.handleResponse(tempURL: tempURL, response: response, error: error)
            Task { @MainActor in
                self?.finish(result, request: request, attempt: attempt, onReady: onReady)
            }
        }

        // O servidor envia Content-Length (FileResponse), então o progresso é real.
        progressObservation = task.progress.observe(\.fractionCompleted) { [weak self] progress, _ in
            let value = progress.fractionCompleted
            Task { @MainActor in self?.downloadProgress = value }
        }

        self.task = task
        task.resume()
    }

    private func finish(_ result: Result<URL, DownloadFailure>,
                        request: URLRequest,
                        attempt: Int,
                        onReady: @escaping (URL) -> Void) {
        progressObservation = nil
        task = nil

        if case .failure(.retryable) = result, attempt < Self.maxAttempts {
            // Render acordando/reiniciando: tenta de novo uma vez, sem incomodar o usuário.
            isRetrying = true
            downloadProgress = 0
            start(request, attempt: attempt + 1, onReady: onReady)
            return
        }

        isDownloading = false
        isRetrying = false

        switch result {
        case .success(let url):
            downloadProgress = 1
            onReady(url)
        case .failure(.cancelled):
            downloadProgress = 0
        case .failure(.retryable(let message)), .failure(.message(let message)):
            downloadProgress = 0
            errorMessage = message
        }
    }

    nonisolated private static func handleResponse(tempURL: URL?,
                                                   response: URLResponse?,
                                                   error: Error?) -> Result<URL, DownloadFailure> {
        if let urlError = error as? URLError {
            switch urlError.code {
            case .cancelled:
                return .failure(.cancelled)
            case .timedOut:
                return .failure(.message("O servidor demorou demais para responder. Tente de novo."))
            case .notConnectedToInternet:
                return .failure(.message("Sem conexão com a internet."))
            case .networkConnectionLost:
                return .failure(.retryable("A conexão caiu durante o download. Tente de novo."))
            case .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed:
                return .failure(.message("Não foi possível alcançar o servidor. Confira o endereço em Servidor."))
            default:
                return .failure(.message(urlError.localizedDescription))
            }
        }
        if let error {
            return .failure(.message(error.localizedDescription))
        }
        guard let tempURL, let http = response as? HTTPURLResponse else {
            return .failure(.message("Resposta inválida do servidor."))
        }

        guard http.statusCode == 200 else {
            // Nos erros o FastAPI responde {"detail": "..."}, que foi salvo no arquivo temporário.
            let detail = (try? Data(contentsOf: tempURL))
                .flatMap { try? JSONDecoder().decode(APIErrorBody.self, from: $0) }?
                .detail
            let message = detail ?? "Erro do servidor (\(http.statusCode))."
            if retryableStatusCodes.contains(http.statusCode) {
                return .failure(.retryable(message))
            }
            if http.statusCode == 404 {
                return .failure(.message("Servidor não encontrado (404). Confira o endereço em Servidor."))
            }
            return .failure(.message(message))
        }

        do {
            let fileManager = FileManager.default
            // Substitui o download anterior em vez de acumular arquivos no cache.
            try? fileManager.removeItem(at: downloadsFolder)
            try fileManager.createDirectory(at: downloadsFolder, withIntermediateDirectories: true)

            // Nome vem do Content-Disposition (título do vídeo), aparece no app e na Tela de Bloqueio.
            let destination = downloadsFolder.appendingPathComponent(fileName(from: http))
            try fileManager.moveItem(at: tempURL, to: destination)
            return .success(destination)
        } catch {
            return .failure(.message("Não foi possível salvar o áudio: \(error.localizedDescription)"))
        }
    }

    nonisolated private static func fileName(from response: HTTPURLResponse) -> String {
        var name = response.suggestedFilename ?? "YouTube.m4a"
        name = name.components(separatedBy: CharacterSet(charactersIn: "/:\\")).joined(separator: " ")
        if !name.lowercased().hasSuffix(".m4a") {
            name = (name as NSString).deletingPathExtension + ".m4a"
        }
        return name
    }

    nonisolated static func looksLikeYouTube(_ link: String) -> Bool {
        guard let host = URL(string: link.trimmingCharacters(in: .whitespacesAndNewlines))?.host?.lowercased() else {
            return false
        }
        return host == "youtu.be" || host == "youtube.com" || host.hasSuffix(".youtube.com")
    }
}

private enum DownloadFailure: Error {
    case cancelled
    /// Falha temporária (servidor acordando, conexão caiu): vale uma nova tentativa.
    case retryable(String)
    case message(String)
}

private struct APIErrorBody: Decodable {
    let detail: String
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
