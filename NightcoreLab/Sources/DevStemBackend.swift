import AVFoundation
import Foundation

/// Explicitly opted-in DEV integration: POST local compressed audio to an
/// authenticated htdemucs worker, then download its four independent WAVs.
/// Disabled by default. The production app never uploads audio automatically.
enum DevStemBackend {
    private enum StemServerFailure: LocalizedError {
        case failed(String)
        var errorDescription: String? {
            switch self {
            case .failed(let reason): return "Demucs: " + reason
            }
        }
    }
    private struct Job: Decodable {
        let id: String
        let status: String
        let message: String?
    }

    private struct Health: Decodable {
        let status: String
        let enabled: Bool
    }

    /// The server returns HTTP errors before a model job exists. Keep failures
    /// actionable without ever disclosing an authentication token.
    static func diagnostic(for status: Int) -> String {
        switch status {
        case 401, 403: return "Token incorreto. Confira o token exibido no PowerShell."
        case 404: return "Endpoint não encontrado. Use apenas a URL raiz HTTPS do túnel."
        case 413: return "Áudio maior que o limite de 35 MB do servidor DEV."
        case 429: return "Servidor ocupado separando outra música. Aguarde o trabalho atual terminar."
        case 502, 503, 504: return "Túnel ou servidor indisponível. Mantenha o PowerShell e o Cloudflared abertos."
        default: return "Servidor retornou HTTP \(status). Confira os logs do PowerShell."
        }
    }

    static var enabled: Bool { UserDefaults.standard.bool(forKey: "stems.devBackendEnabled") }

    static func endpoint() -> URL? {
        guard enabled,
              let raw = UserDefaults.standard.string(forKey: "stems.devBackendURL")?
                  .trimmingCharacters(in: .whitespacesAndNewlines),
              let url = URL(string: raw), let host = url.host,
              url.scheme == "https" || (url.scheme == "http" &&
                     ["localhost", "127.0.0.1"].contains(host)),
              url.user == nil, url.password == nil else { return nil }
        return url
    }

    static func separate(source: URL, cacheFolder: URL, server: URL,
                         onStatus: (@Sendable (String) async -> Void)? = nil) async throws -> StemAsset {
        guard let size = (try? source.resourceValues(forKeys: [.fileSizeKey])).flatMap(\.fileSize),
              size > 0, size <= 35 * 1024 * 1024 else {
            throw StemServerFailure.failed("Selecione um arquivo local válido de até 35 MB.")
        }
        let token = StemDevCredentials.load() ?? ""
        guard token.count >= 16 else {
            throw StemServerFailure.failed("Insira o token do servidor (mínimo 16 caracteres) no Modo DEV.")
        }
        await onStatus?("Verificando conexão com o servidor Demucs…")
        var healthRequest = URLRequest(url: server.appendingPathComponent("health"))
        healthRequest.timeoutInterval = 12
        let healthData: Data
        let healthResponse: URLResponse
        do {
            (healthData, healthResponse) = try await URLSession.shared.data(for: healthRequest)
        } catch {
            throw StemServerFailure.failed(
                "Servidor inacessível: verifique a URL HTTPS e mantenha a janela do PowerShell aberta. \(error.localizedDescription)")
        }
        guard let healthHTTP = healthResponse as? HTTPURLResponse else {
            throw StemServerFailure.failed("Resposta inválida do túnel Cloudflare.")
        }
        guard healthHTTP.statusCode == 200 else {
            throw StemServerFailure.failed(diagnostic(for: healthHTTP.statusCode))
        }
        guard let health = try? JSONDecoder().decode(Health.self, from: healthData),
              health.status == "ok", health.enabled else {
            throw StemServerFailure.failed("O endereço não aponta para um servidor Demucs DEV ativo.")
        }
        try Task.checkCancellation()
        await onStatus?("Enviando o áudio ao computador…")
        var request = URLRequest(url: server.appendingPathComponent("api/stems"))
        request.httpMethod = "POST"
        request.timeoutInterval = 90
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        let responseData: Data
        let response: URLResponse
        do {
            (responseData, response) = try await URLSession.shared.upload(for: request, fromFile: source)
        } catch {
            throw StemServerFailure.failed("Falha ao enviar áudio pelo túnel: \(error.localizedDescription)")
        }
        guard let http = response as? HTTPURLResponse else {
            throw StemServerFailure.failed("O servidor não retornou uma resposta HTTP.")
        }
        guard http.statusCode == 202 else {
            throw StemServerFailure.failed(diagnostic(for: http.statusCode))
        }
        let job = try JSONDecoder().decode(Job.self, from: responseData)
        guard !job.id.isEmpty, job.id.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" }) else {
            throw URLError(.cannotParseResponse)
        }
        let jobURL = server.appendingPathComponent("api/stems").appendingPathComponent(job.id)
        var ready = false
        // HTDemucs may take up to 12 minutes on a CPU-only developer laptop.
        // Allow 15 minutes so the server can return a real error/ready status.
        await onStatus?("Áudio recebido. Separando voz, bateria, baixo e instrumentos no computador…")
        for attempt in 0..<300 {
            try Task.checkCancellation()
            var polling = URLRequest(url: jobURL)
            polling.timeoutInterval = 20
            polling.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
            let (data, reply) = try await URLSession.shared.data(for: polling)
            guard let status = (reply as? HTTPURLResponse)?.statusCode, status == 200 else {
                throw StemServerFailure.failed(diagnostic(for: (reply as? HTTPURLResponse)?.statusCode ?? 0))
            }
            let result = try JSONDecoder().decode(Job.self, from: data)
            if result.status == "ready" { ready = true; break }
            if result.status == "failed" {
                throw StemServerFailure.failed(result.message ?? "O processamento falhou no servidor.")
            }
            if attempt % 5 == 0 {
                await onStatus?("Demucs processando no computador · \(attempt * 3)s decorridos. Pode levar vários minutos.")
            }
            try await Task.sleep(for: .seconds(3))
        }
        guard ready else {
            throw StemServerFailure.failed("A separação ultrapassou o tempo limite. Confira o servidor no PowerShell.")
        }
        await onStatus?("Separação concluída. Baixando quatro stems…")
        let folder = cacheFolder.appendingPathComponent("demucs-" + job.id, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var paths: [StemKind: URL] = [:]
        let remoteNames: [StemKind: String] = [
            .vocal: "vocals", .instrumental: "other", .drums: "drums", .bass: "bass"
        ]
        do {
            var duration: Double?
            for (index, kind) in StemKind.allCases.enumerated() {
                try Task.checkCancellation()
                await onStatus?("Baixando e validando stem \(index + 1) de 4…")
                let name = remoteNames[kind]!
                var fetch = URLRequest(url: jobURL.appendingPathComponent(name))
                fetch.timeoutInterval = 180
                fetch.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
                let (temporary, response) = try await URLSession.shared.download(for: fetch)
                guard let status = (response as? HTTPURLResponse)?.statusCode, status == 200 else {
                    throw StemServerFailure.failed(diagnostic(for: (response as? HTTPURLResponse)?.statusCode ?? 0))
                }
                let output = folder.appendingPathComponent(kind.rawValue + ".wav")
                try FileManager.default.moveItem(at: temporary, to: output)
                let file = try AVAudioFile(forReading: output)
                guard file.length > 0, file.processingFormat.sampleRate > 0 else {
                    throw CocoaError(.fileReadCorruptFile)
                }
                let seconds = Double(file.length) / file.processingFormat.sampleRate
                if let duration, abs(duration - seconds) > 0.050 {
                    throw CocoaError(.fileReadCorruptFile)
                }
                duration = seconds
                paths[kind] = output
            }
            return StemAsset(urls: paths, source: .demucs)
        } catch {
            try? FileManager.default.removeItem(at: folder)
            throw error
        }
    }
}
