import Foundation

/// Consome o microserviço FastAPI: POST /download {"url": ...} → .m4a em streaming.
@MainActor
final class DownloadManager: ObservableObject {

    // MARK: Configuração

    /// Endereço do microserviço (sem barra no final).
    /// Teste na rede local: use o IP do PC, ex. "http://192.168.0.10:8000".
    static var apiBaseURL = "https://SEU-SERVICO.onrender.com"

    /// Generoso de propósito: cold start do Render (~50 s) + extração do yt-dlp no servidor.
    private static let requestTimeout: TimeInterval = 180

    /// Pasta própria dos downloads: é esvaziada a cada novo download, então só existe
    /// um arquivo baixado por vez no cache.
    nonisolated private static let downloadsFolder = FileManager.default.temporaryDirectory
        .appendingPathComponent("youtube", isDirectory: true)

    // MARK: Estado

    @Published private(set) var isDownloading = false
    @Published var errorMessage: String?
    /// 0 enquanto o servidor ainda extrai o áudio; de 0 a 1 durante a transferência.
    @Published private(set) var downloadProgress: Double = 0

    private var task: URLSessionDownloadTask?
    private var progressObservation: NSKeyValueObservation?

    // MARK: API

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
            errorMessage = "Endereço da API inválido."
            return
        }

        var request = URLRequest(url: endpoint, timeoutInterval: Self.requestTimeout)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONEncoder().encode(["url": link])

        isDownloading = true
        errorMessage = nil
        downloadProgress = 0

        let task = URLSession.shared.downloadTask(with: request) { [weak self] tempURL, response, error in
            // Fila de background. O arquivo temporário é apagado pelo sistema assim que
            // este bloco retorna, então ele precisa ser movido aqui, de forma síncrona.
            let result = Self.handleResponse(tempURL: tempURL, response: response, error: error)
            Task { @MainActor in self?.finish(result, onReady: onReady) }
        }

        // O servidor envia Content-Length (FileResponse), então o progresso é real.
        progressObservation = task.progress.observe(\.fractionCompleted) { [weak self] progress, _ in
            let value = progress.fractionCompleted
            Task { @MainActor in self?.downloadProgress = value }
        }

        self.task = task
        task.resume()
    }

    func cancel() {
        task?.cancel()
    }

    // MARK: Privado

    private func finish(_ result: Result<URL, DownloadFailure>, onReady: (URL) -> Void) {
        progressObservation = nil
        task = nil
        isDownloading = false

        switch result {
        case .success(let url):
            downloadProgress = 1
            onReady(url)
        case .failure(.cancelled):
            downloadProgress = 0
        case .failure(.message(let message)):
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
            case .notConnectedToInternet, .networkConnectionLost:
                return .failure(.message("Sem conexão com a internet."))
            case .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed:
                return .failure(.message("Não foi possível alcançar o servidor."))
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
            return .failure(.message(detail ?? "Erro do servidor (\(http.statusCode))."))
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

    nonisolated private static func looksLikeYouTube(_ link: String) -> Bool {
        guard let host = URL(string: link)?.host?.lowercased() else { return false }
        return host == "youtu.be" || host == "youtube.com" || host.hasSuffix(".youtube.com")
    }
}

private enum DownloadFailure: Error {
    case cancelled
    case message(String)
}

private struct APIErrorBody: Decodable {
    let detail: String
}
