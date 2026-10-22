import AVFoundation
import CryptoKit
import Foundation

/// Render signs an admission; all audio and WAV transfers go directly to the
/// configured ZeroGPU Space. A personal free Read token is sent only to the
/// pinned community Space; never to Render or a paid inference endpoint.
enum CloudStemWorker {
    typealias Transfer = @Sendable (URL, String) async throws -> URL
    enum Failure: LocalizedError {
        case message(String)
        var errorDescription: String? { if case .message(let text) = self { return text }; return nil }
    }
    struct Admission: Codable {
        let ticket: String
        let space_url: URL
        let model: String
        let provider: String?
    }
    static let communityURL = URL(string: "https://d-r-e-audio-separator.hf.space")!
    static let communityModel = "bs-roformer-musdb18hq"
    private static let clientID: String = {
        let key = "gnarly.cloud-stems.client.v1"
        if let saved = UserDefaults.standard.string(forKey: key), UUID(uuidString: saved) != nil { return saved }
        let value = UUID().uuidString
        UserDefaults.standard.set(value, forKey: key)
        return value
    }()
    struct Manifest: Codable {
        let model: String
        let source_hash: String
        let frames: Int64
        let sample_rate: Int
        let sha256: [String: String]
    }
    struct Pending: Codable {
        var admission: Admission?
        var admissionKey: String?
        var remotePath: String?
        var submitting = false
        var eventID: String?
        var payload: Data?
        func save(to url: URL) throws {
            try JSONEncoder().encode(self).write(to: url, options: .atomic)
        }
    }
    static func hasSavedRequest(source: URL, workFolder: URL = StemJobJournal.root) -> Bool {
        guard let digest = try? hash(source),
              let data = try? Data(contentsOf: workFolder.appendingPathComponent("cloud-" + digest).appendingPathComponent("pending.json")),
              let pending = try? JSONDecoder().decode(Pending.self, from: data) else { return false }
        return pending.admission != nil
    }
    static func discardSavedRequest(source: URL) {
        guard let digest = try? hash(source) else { return }
        try? FileManager.default.removeItem(at: StemJobJournal.root.appendingPathComponent("cloud-" + digest))
    }
    enum ProviderFailure: LocalizedError {
        case rejected
        var errorDescription: String? { "A GPU encerrou este pedido sem concluir. Se a cota do provedor acabou, aguarde a renovação; a troca de música não cria outro pedido." }
    }
    static func streamPayload(_ data: Data) throws -> Data {
        guard data.count <= 1_000_000, let text = String(data: data, encoding: .utf8) else {
            throw Failure.message("Resposta da GPU excedeu o limite.")
        }
        var event = ""
        for line in text.components(separatedBy: .newlines) {
            if line.hasPrefix("event: ") { event = String(line.dropFirst(7)) }
            if event == "error", line.hasPrefix("data: ") { throw ProviderFailure.rejected }
            if event == "complete", line.hasPrefix("data: ") { return Data(line.dropFirst(6).utf8) }
        }
        throw Failure.message("A conexão foi interrompida. O pedido está salvo; retome sem enviar outra separação.")
    }

    /// Gradio uses an open SSE connection, often with heartbeats; a background
    /// download waits for EOF and can leave the UI at 10% indefinitely.
    /// Parse individual events and return immediately on the complete event.
    enum SSEUpdate {
        case heartbeat
        case queued
        case running
        case complete(Data)
    }
    struct SSEEvents {
        private var eventName = ""
        private var fields: [String] = []
        private var bytes = 0

        mutating func feed(_ line: String) throws -> SSEUpdate? {
            if line.isEmpty {
                let name = eventName
                let body = fields.joined(separator: "\n")
                eventName = ""
                fields.removeAll(keepingCapacity: true)
                bytes = 0
                switch name {
                case "complete":
                    guard !body.isEmpty else {
                        throw Failure.message("A GPU terminou sem entregar stems. O pedido foi preservado.")
                    }
                    return .complete(Data(body.utf8))
                case "error":
                    throw ProviderFailure.rejected
                case "generating", "processing":
                    return .running
                case "pending", "queue", "queued":
                    return .queued
                case "heartbeat":
                    return .heartbeat
                default:
                    return nil
                }
            }
            if line.hasPrefix("event:") {
                eventName = String(line.dropFirst(6)).trimmingCharacters(in: .whitespaces)
            } else if line.hasPrefix("data:") {
                let value = String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces)
                bytes += value.utf8.count + 1
                guard bytes <= 1_000_000 else { throw Failure.message("Resposta da GPU excedeu o limite.") }
                fields.append(value)
            }
            return nil
        }
    }

    /// GET is read-only and references the exact saved Gradio event_id:
    /// reconnecting never submits another inference or spends another admission.
    static func awaitSavedResult(url: URL, token: String, session: URLSession,
                                 progress: @escaping @Sendable (Double, String) -> Void) async throws -> Data {
        let request = try HuggingFaceAccess.authorize(URLRequest(url: url), token: token)
        return try await withThrowingTaskGroup(of: Data.self) { group in
            group.addTask {
                let (lines, response) = try await session.bytes(for: request)
                guard let http = response as? HTTPURLResponse,
                      (200..<300).contains(http.statusCode),
                      http.url?.scheme == url.scheme, http.url?.host == url.host,
                      http.url?.port == url.port else {
                    if (response as? HTTPURLResponse)?.statusCode == 429 {
                        throw Failure.message("A GPU limitou o acesso (429). O pedido está salvo; retome após a cota renovar.")
                    }
                    throw Failure.message("Não foi possível consultar o pedido na GPU. Ele permanece salvo para retomar.")
                }
                guard http.value(forHTTPHeaderField: "Content-Type")?.lowercased()
                    .contains("text/event-stream") == true else {
                    throw Failure.message("A GPU retornou um formato inesperado. Pedido preservado; não será reenviado.")
                }
                var events = SSEEvents()
                let started = ProcessInfo.processInfo.systemUptime
                for try await line in lines.lines {
                    try Task.checkCancellation()
                    guard let update = try events.feed(line) else { continue }
                    switch update {
                    case .heartbeat:
                        let seconds = Int(ProcessInfo.processInfo.systemUptime - started)
                        progress(0.1, "GPU conectada · esperando resposta há \(seconds / 60) min \(seconds % 60) s")
                    case .queued:
                        progress(0.1, "Na fila da GPU gratuita · pedido salvo, sem reenvio")
                    case .running:
                        progress(0.1, "GPU processando os stems · a música continua disponível")
                    case .complete(let payload):
                        progress(0.6, "Separação concluída · recebendo os quatro stems…")
                        return payload
                    }
                }
                if case .complete(let payload)? = try events.feed("") { return payload }
                throw Failure.message("A conexão com a GPU foi interrompida. Retome o pedido salvo sem gerar outro.")
            }
            group.addTask {
                try await Task.sleep(for: .seconds(720))
                throw Failure.message("A GPU não concluiu em 12 minutos. O pedido continua salvo; retome para consultar a mesma tarefa.")
            }
            defer { group.cancelAll() }
            guard let result = try await group.next() else {
                throw Failure.message("A conexão da GPU não respondeu. O pedido segue salvo.")
            }
            return result
        }
    }

    static let names: [(StemKind, String)] = [(.vocal, "vocals"), (.instrumental, "other"),
                                              (.drums, "drums"), (.bass, "bass")]
    private final class NoRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        func urlSession(_ session: URLSession, task: URLSessionTask,
                        willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest,
                        completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
    }

    static func permittedSpace(_ url: URL) -> Bool {
        guard url.scheme == "https", url.user == nil, url.password == nil, url.port == nil,
              url.query == nil, url.fragment == nil, url.path.isEmpty || url.path == "/",
              let host = url.host else { return false }
        return host.range(of: #"^[a-z0-9]+(?:-[a-z0-9]+)*\.hf\.space$"#,
                          options: .regularExpression) != nil
    }
    static func permittedDownload(_ url: URL, space: URL) -> Bool {
        permittedSpace(space) && url.scheme == "https" && url.host == space.host &&
        url.port == nil && url.user == nil && url.password == nil &&
        url.path.hasPrefix("/gradio_api/file=")
    }

    static func hash(_ url: URL) throws -> String {
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        var digest = SHA256()
        while let chunk = try file.read(upToCount: 512 * 1024), !chunk.isEmpty {
            try Task.checkCancellation(); digest.update(data: chunk)
        }
        return digest.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func completion(_ data: Data, space: URL, sourceHash: String) throws -> ([URL], Manifest) {
        guard let values = try JSONSerialization.jsonObject(with: data) as? [Any], values.count == 5,
              let metadata = values.last,
              JSONSerialization.isValidJSONObject(metadata) else {
            throw Failure.message("Resposta inválida da GPU gratuita.")
        }
        let manifest = try JSONDecoder().decode(Manifest.self,
                            from: JSONSerialization.data(withJSONObject: metadata))
        guard manifest.model == "htdemucs", manifest.source_hash == sourceHash,
              manifest.sample_rate == 44_100, manifest.frames > 0, manifest.frames < 600 * 44_100,
              names.allSatisfy({ manifest.sha256[$0.1]?.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil }) else {
            throw Failure.message("Os stems recebidos não correspondem à música.")
        }
        let urls = try values.prefix(4).map { value -> URL in
            guard let file = value as? [String: Any], let text = file["url"] as? String,
                  let url = URL(string: text), permittedDownload(url, space: space) else {
                throw Failure.message("Endereço de download de stems inválido.")
            }
            return url
        }
        return (urls, manifest)
    }

    /// Public Space contract: status, four named files, ZIP, HTML. Only the
    /// individually validated WAVs are used; HTML is never rendered or executed.
    /// This provider does not attest the original source hash or file SHA-256;
    /// local checksums are recorded after HTTPS download and audio validation.
    static func communityCompletion(_ data: Data, space: URL) throws -> [URL] {
        guard space == communityURL,
              let values = try JSONSerialization.jsonObject(with: data) as? [Any], values.count == 4,
              let files = values[1] as? [[String: Any]], files.count == 4 else {
            throw Failure.message("O serviço comunitário retornou um formato incompatível.")
        }
        var found: [String: URL] = [:]
        for file in files {
            guard let name = file["orig_name"] as? String,
                  let match = names.first(where: { name.range(of: "^(?:[0-9]+_)?" + $0.1 + "\\.wav$", options: .regularExpression) != nil }),
                  found[match.1] == nil,
                  let text = file["url"] as? String, let url = URL(string: text),
                  permittedDownload(url, space: space), url.lastPathComponent == name else {
                throw Failure.message("O serviço não retornou os quatro stems esperados.")
            }
            found[match.1] = url
        }
        return try names.map {
            guard let url = found[$0.1] else { throw Failure.message("Um stem está ausente.") }
            return url
        }
    }

    private static func requireSuccess(_ response: URLResponse, data: Data? = nil) throws {
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            if let data, let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let detail = object["detail"] as? String {
                throw Failure.message(String(detail.prefix(240)))
            }
            if (response as? HTTPURLResponse)?.statusCode == 429 {
                throw Failure.message("O serviço aplicou um limite temporário. Aguarde o intervalo informado antes de iniciar uma nova separação.")
            }
            throw Failure.message("O serviço da GPU não respondeu corretamente. O pedido salvo será preservado para retomada.")
        }
    }
    private static func json(_ body: [String: Any], url: URL) throws -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    static func prepare(source: URL, betaCode: String,
                        cacheFolder: URL = NeuralStemWorker.cacheRoot,
                        workFolder: URL = StemJobJournal.root,
                        serverURL: URL? = nil, requestSession: URLSession? = nil,
                        hfToken: String? = nil, transfer: Transfer? = nil,
                        progress: @escaping @Sendable (Double, String) -> Void) async throws -> StemAsset {
        do { return try await run(source: source, betaCode: betaCode, cacheFolder: cacheFolder,
            workFolder: workFolder, serverURL: serverURL, requestSession: requestSession,
            hfToken: hfToken, transfer: transfer, progress: progress) }
        catch {
            if Task.isCancelled { throw CancellationError() }
            throw error
        }
    }

    private static func run(source: URL, betaCode: String,
                            cacheFolder: URL, workFolder: URL, serverURL: URL?, requestSession: URLSession?,
                            hfToken: String?, transfer suppliedTransfer: Transfer?,
                            progress: @escaping @Sendable (Double, String) -> Void) async throws -> StemAsset {
        progress(0, "Conferindo música e stems salvos…")
        let input = try AVAudioFile(forReading: source)
        let seconds = Double(input.length) / input.processingFormat.sampleRate
        let size = try source.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard seconds > 0, seconds < 600, size > 0, size <= 35 * 1024 * 1024 else {
            throw Failure.message("Na nuvem gratuita, use músicas com menos de 10 minutos e até 35 MB.")
        }
        let digest = try hash(source)
        let root = cacheFolder
        func asset(_ directory: URL, model: String) -> StemAsset {
            StemAsset(urls: Dictionary(uniqueKeysWithValues: names.map {
                ($0.0, directory.appendingPathComponent($0.1 + ".wav"))
            }), source: model == communityModel ? .roformer : .demucs)
        }
        for model in [communityModel, "htdemucs"] {
            let folder = root.appendingPathComponent("cloud-" + model + "-v1-" + digest, isDirectory: true)
            if let data = try? Data(contentsOf: folder.appendingPathComponent("complete.json")),
               let manifest = try? JSONDecoder().decode(Manifest.self, from: data),
               manifest.model == model, manifest.source_hash == digest,
               let frames = try? NeuralStemWorker.validate(asset(folder, model: model), expectedSeconds: seconds),
               frames == manifest.frames {
                progress(1, "Stems salvos neste iPhone")
                return asset(folder, model: model)
            }
        }
        let server = await MainActor.run { AudioDownloadManager.apiBaseURL }
        guard let base = serverURL ?? URL(string: server), base.scheme == "https" else {
            throw Failure.message("Configure um servidor HTTPS antes de usar a nuvem.")
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 180
        configuration.timeoutIntervalForResource = 900
        configuration.httpCookieStorage = nil
        let session = requestSession ?? URLSession(configuration: configuration, delegate: NoRedirects(), delegateQueue: nil)
        defer { if requestSession == nil { session.invalidateAndCancel() } }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let stage = workFolder.appendingPathComponent("cloud-" + digest, isDirectory: true)
        let savedBytes = names.reduce(Int64(0)) { sum, item in
            sum + Int64((try? stage.appendingPathComponent(item.1 + ".wav").resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        let required = max(100_000_000, Int64(seconds * 44_100 * 8 * 4) + Int64(size) + 100_000_000 - savedBytes)
        if let free = try? root.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            .volumeAvailableCapacityForImportantUsage, free < required {
            throw NeuralStemError.insufficientSpace
        }
        try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: true)
        let pendingURL = stage.appendingPathComponent("pending.json")
        var pending = (try? Data(contentsOf: pendingURL)).flatMap { try? JSONDecoder().decode(Pending.self, from: $0) } ?? Pending()
        if pending.admission == nil {
            if pending.admissionKey == nil { pending.admissionKey = UUID().uuidString }
            try pending.save(to: pendingURL)
            var admissionRequest = try json(["sha256": digest, "bytes": size, "seconds": seconds],
                                           url: base.appendingPathComponent("v1/stems/cloud/ticket"))
            admissionRequest.setValue(pending.admissionKey, forHTTPHeaderField: "Idempotency-Key")
            admissionRequest.setValue(clientID, forHTTPHeaderField: "X-Gnarly-Client")
            if !betaCode.isEmpty { admissionRequest.setValue("Bearer " + betaCode, forHTTPHeaderField: "Authorization") }
            let (admissionData, admissionResponse) = try await session.data(for: admissionRequest)
            try requireSuccess(admissionResponse, data: admissionData)
            pending.admission = try JSONDecoder().decode(Admission.self, from: admissionData)
            try pending.save(to: pendingURL)
        }
        guard let admission = pending.admission else { throw Failure.message("Pedido salvo inválido.") }
        let community = admission.provider == "community_bs_roformer"
        let validProfile = community
            ? (admission.model == communityModel && admission.space_url == communityURL)
            : (admission.model == "htdemucs" && (admission.provider == nil || admission.provider == "owned_htdemucs"))
        guard permittedSpace(admission.space_url), validProfile else {
            throw Failure.message("O servidor não autorizou um Space ZeroGPU válido.")
        }
        let space = admission.space_url
        let token = community ? (hfToken ?? HuggingFaceAccess.read()) : ""
        if !token.isEmpty, pending.eventID == nil {
            progress(0.02, "Conectando sua conta gratuita do Hugging Face…")
            _ = try await HuggingFaceAccess.verify(token, session: session)
        }
        let transfer: Transfer = suppliedTransfer ?? { url, key in
            let request = try HuggingFaceAccess.authorize(URLRequest(url: url), token: token)
            return try await CloudStemTransfer.shared.download(request, key: key)
        }
        let folder = root.appendingPathComponent("cloud-" + admission.model + "-v1-" + digest, isDirectory: true)
        if pending.remotePath == nil {
        let multipart = stage.appendingPathComponent("upload.bin")
        let boundary = "Gnarly" + UUID().uuidString
        // Build on disk in chunks, never load a complete song into RAM.
        FileManager.default.createFile(atPath: multipart.path, contents: nil)
        let output = try FileHandle(forWritingTo: multipart)
        do {
            try output.write(contentsOf: Data(("--\(boundary)\r\nContent-Disposition: form-data; name=\"files\"; filename=\"source.m4a\"\r\nContent-Type: application/octet-stream\r\n\r\n").utf8))
            let handle = try FileHandle(forReadingFrom: source)
            defer { try? handle.close() }
            while let chunk = try handle.read(upToCount: 512 * 1024), !chunk.isEmpty {
                try Task.checkCancellation(); try output.write(contentsOf: chunk)
            }
            try output.write(contentsOf: Data("\r\n--\(boundary)--\r\n".utf8))
            try output.close()
        } catch { try? output.close(); throw error }
        progress(0.05, "Enviando áudio ao Hugging Face…")
        var upload = URLRequest(url: space.appendingPathComponent("gradio_api/upload"))
        upload.httpMethod = "POST"
        upload.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        upload = try HuggingFaceAccess.authorize(upload, token: token)
        let (uploadData, uploadResponse) = try await session.upload(for: upload, fromFile: multipart)
        try requireSuccess(uploadResponse)
        try FileManager.default.removeItem(at: multipart)
        guard let remotePath = try JSONDecoder().decode([String].self, from: uploadData).first else {
            throw Failure.message("O envio do áudio não foi concluído.")
        }
        pending.remotePath = remotePath
        try pending.save(to: pendingURL)
        }
        let callURL = space.appendingPathComponent("gradio_api/call/separate")
        if pending.eventID == nil {
        // A lost POST response cannot be retried safely: the provider has no
        // idempotency key. Preserve that ambiguity rather than spend more quota.
        guard !pending.submitting else {
            throw Failure.message("O envio do pedido ficou sem confirmação. Não enviaremos outro automaticamente para preservar a cota. Aguarde antes de iniciar uma nova separação.")
        }
        let fileData: [String: Any] = ["path": pending.remotePath!, "meta": ["_type": "gradio.FileData"]]
        let arguments: [Any] = community ? [fileData, "Core instruments — 4 tracks"] : [fileData, admission.ticket]
        let call = try HuggingFaceAccess.authorize(json(["data": arguments], url: callURL), token: token)
        pending.submitting = true
        try pending.save(to: pendingURL)
        let (callData, callResponse) = try await session.data(for: call)
        if let http = callResponse as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            pending.submitting = false
            try pending.save(to: pendingURL)
        }
        try requireSuccess(callResponse)
        guard let callObject = try JSONSerialization.jsonObject(with: callData) as? [String: String],
              let eventID = callObject["event_id"],
              eventID.range(of: "^[a-f0-9]{32}$", options: .regularExpression) != nil else {
            throw Failure.message("A fila da GPU não aceitou o pedido.")
        }
        pending.eventID = eventID
        try pending.save(to: pendingURL)
        }
        guard let eventID = pending.eventID,
              eventID.range(of: "^[a-f0-9]{32}$", options: .regularExpression) != nil else {
            throw Failure.message("Identificador do pedido salvo inválido.")
        }
        if pending.payload == nil {
            progress(0.1, "Acompanhando o pedido salvo na GPU gratuita…")
            if suppliedTransfer != nil {
                // Test/injected file transport retains its deterministic fixture path.
                let response = try await transfer(callURL.appendingPathComponent(eventID), digest + "-" + eventID)
                let bytes = try response.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                guard bytes <= 1_000_000 else { throw Failure.message("Resposta da GPU excedeu o limite.") }
                do { pending.payload = try streamPayload(Data(contentsOf: response)) }
                catch is ProviderFailure {
                    try? FileManager.default.removeItem(at: pendingURL)
                    CloudStemTransfer.shared.remove(digest + "-" + eventID)
                    throw ProviderFailure.rejected
                }
                catch {
                    CloudStemTransfer.shared.remove(digest + "-" + eventID)
                    throw error
                }
            } else {
                // Streaming interpretation: complete arrives before socket EOF.
                // GET is safe to repeat for the same event, POST never is.
                do {
                    pending.payload = try await awaitSavedResult(
                        url: callURL.appendingPathComponent(eventID), token: token,
                        session: session, progress: progress)
                } catch is ProviderFailure {
                    try? FileManager.default.removeItem(at: pendingURL)
                    throw ProviderFailure.rejected
                }
            }
            try pending.save(to: pendingURL)
            CloudStemTransfer.shared.remove(digest + "-" + eventID)
        }
        guard let payload = pending.payload else { throw Failure.message("O pedido está salvo e aguarda resultado.") }
        let urls: [URL]
        let expected: Manifest?
        if community {
            urls = try communityCompletion(payload, space: space); expected = nil
        } else {
            let result = try completion(payload, space: space, sourceHash: digest)
            urls = result.0; expected = result.1
        }
        // Four daemon-owned downloads overlap network latency, with bounded disk
        // buffers. Keep completed siblings even if one transfer is interrupted.
        var hashes: [String: String] = [:]
        var firstError: Error?
        await withTaskGroup(of: Result<(String, String), Error>.self) { group in
            for (index, item) in names.enumerated() {
                let destination = stage.appendingPathComponent(item.1 + ".wav")
                let remoteURL = urls[index]
                let key = digest + "-" + eventID + "-" + item.1
                group.addTask {
                    do {
                        let temporary = FileManager.default.fileExists(atPath: destination.path)
                            ? destination : try await transfer(remoteURL, key)
                        var valid = false
                        defer {
                            if !valid {
                                try? FileManager.default.removeItem(at: temporary)
                                CloudStemTransfer.shared.remove(key)
                            }
                        }
                        try Task.checkCancellation()
                        let byteCount = try temporary.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                        let checksum = try hash(temporary)
                        let audio = try AVAudioFile(forReading: temporary)
                        let maximumFrames = expected?.frames ?? Int64((seconds * 44_100).rounded())
                        guard byteCount > 0, byteCount <= maximumFrames * 8 + 1_000_000,
                              audio.processingFormat.sampleRate == 44_100,
                              audio.processingFormat.channelCount == 2,
                              abs(Double(audio.length) / 44_100 - seconds) <= 0.1,
                              expected == nil || checksum == expected?.sha256[item.1] else {
                            throw Failure.message("Um stem chegou incompleto. O restante está salvo; retome para baixar somente o que falta.")
                        }
                        if temporary != destination { try FileManager.default.moveItem(at: temporary, to: destination) }
                        valid = true
                        CloudStemTransfer.shared.remove(key)
                        return .success((item.1, checksum))
                    } catch { return .failure(error) }
                }
            }
            for await outcome in group {
                switch outcome {
                case .success(let (name, checksum)):
                    hashes[name] = checksum
                    progress(0.6 + Double(hashes.count) * 0.09, "Stems salvos \(hashes.count)/4 · downloads em paralelo…")
                case .failure(let error): if firstError == nil { firstError = error }
                }
            }
        }
        if let firstError { throw firstError }
        let result = asset(stage, model: admission.model)
        let frames = try NeuralStemWorker.validate(result, expectedSeconds: seconds)
        if let expected, frames != expected.frames { throw NeuralStemError.invalidOutput }
        let manifest = Manifest(model: admission.model, source_hash: digest, frames: frames,
                                sample_rate: 44_100, sha256: hashes)
        try JSONEncoder().encode(manifest).write(to: stage.appendingPathComponent("complete.json"), options: .atomic)
        try Task.checkCancellation()
        if FileManager.default.fileExists(atPath: folder.path) { try FileManager.default.removeItem(at: folder) }
        try FileManager.default.moveItem(at: stage, to: folder)
        try? FileManager.default.removeItem(at: folder.appendingPathComponent("pending.json"))
        progress(1, "Stems reais salvos para usar offline")
        return asset(folder, model: admission.model)
    }
}
