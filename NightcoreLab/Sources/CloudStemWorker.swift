import AVFoundation
import CryptoKit
import Foundation

/// Render signs an admission; all audio and WAV transfers go directly to the
/// configured ZeroGPU Space. Never sends a Hugging Face token or buys credits.
enum CloudStemWorker {
    enum Failure: LocalizedError {
        case message(String)
        var errorDescription: String? { if case .message(let text) = self { return text }; return nil }
    }
    struct Admission: Decodable {
        let ticket: String
        let space_url: URL
        let model: String
        let provider: String?
    }
    static let communityURL = URL(string: "https://d-r-e-audio-separator.hf.space")!
    static let communityModel = "bs-roformer-musdb18hq"
    struct Manifest: Codable {
        let model: String
        let source_hash: String
        let frames: Int64
        let sample_rate: Int
        let sha256: [String: String]
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
            throw Failure.message("GPU gratuita indisponível ou cota esgotada. Tente mais tarde ou use o iPhone.")
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
                        progress: @escaping @Sendable (Double, String) -> Void) async throws -> StemAsset {
        do { return try await run(source: source, betaCode: betaCode, progress: progress) }
        catch {
            if Task.isCancelled { throw CancellationError() }
            throw error
        }
    }

    private static func run(source: URL, betaCode: String,
                            progress: @escaping @Sendable (Double, String) -> Void) async throws -> StemAsset {
        progress(0, "Conferindo música e stems salvos…")
        let input = try AVAudioFile(forReading: source)
        let seconds = Double(input.length) / input.processingFormat.sampleRate
        let size = try source.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard seconds > 0, seconds < 600, size > 0, size <= 35 * 1024 * 1024 else {
            throw Failure.message("Na nuvem gratuita, use músicas com menos de 10 minutos e até 35 MB.")
        }
        let digest = try hash(source)
        let root = NeuralStemWorker.cacheRoot
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
        guard let base = URL(string: server), base.scheme == "https" else {
            throw Failure.message("Configure um servidor HTTPS antes de usar a nuvem.")
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 180
        configuration.timeoutIntervalForResource = 900
        configuration.httpCookieStorage = nil
        let session = URLSession(configuration: configuration, delegate: NoRedirects(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let required = Int64(seconds * 44_100 * 8 * 4) + Int64(size) + 100_000_000
        if let free = try? root.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            .volumeAvailableCapacityForImportantUsage, free < required {
            throw NeuralStemError.insufficientSpace
        }
        var admissionRequest = try json(["sha256": digest, "bytes": size, "seconds": seconds],
                                       url: base.appendingPathComponent("v1/stems/cloud/ticket"))
        if !betaCode.isEmpty { admissionRequest.setValue("Bearer " + betaCode, forHTTPHeaderField: "Authorization") }
        let (admissionData, admissionResponse) = try await session.data(for: admissionRequest)
        try requireSuccess(admissionResponse, data: admissionData)
        let admission = try JSONDecoder().decode(Admission.self, from: admissionData)
        let community = admission.provider == "community_bs_roformer"
        let validProfile = community
            ? (admission.model == communityModel && admission.space_url == communityURL)
            : (admission.model == "htdemucs" && (admission.provider == nil || admission.provider == "owned_htdemucs"))
        guard permittedSpace(admission.space_url), validProfile else {
            throw Failure.message("O servidor não autorizou um Space ZeroGPU válido.")
        }
        let space = admission.space_url
        let folder = root.appendingPathComponent("cloud-" + admission.model + "-v1-" + digest, isDirectory: true)
        let stage = root.appendingPathComponent(".cloud-partial-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: stage) }
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
        let (uploadData, uploadResponse) = try await session.upload(for: upload, fromFile: multipart)
        try requireSuccess(uploadResponse)
        try FileManager.default.removeItem(at: multipart)
        guard let remotePath = try JSONDecoder().decode([String].self, from: uploadData).first else {
            throw Failure.message("O envio do áudio não foi concluído.")
        }
        let callURL = space.appendingPathComponent("gradio_api/call/separate")
        let fileData: [String: Any] = ["path": remotePath, "meta": ["_type": "gradio.FileData"]]
        let arguments: [Any] = community ? [fileData, "Core instruments — 4 tracks"] : [fileData, admission.ticket]
        let call = try json(["data": arguments], url: callURL)
        let (callData, callResponse) = try await session.data(for: call)
        try requireSuccess(callResponse)
        guard let callObject = try JSONSerialization.jsonObject(with: callData) as? [String: String],
              let eventID = callObject["event_id"],
              eventID.range(of: "^[a-f0-9]{32}$", options: .regularExpression) != nil else {
            throw Failure.message("A fila da GPU não aceitou o pedido.")
        }
        progress(0.1, "Aguardando fila e separação na GPU gratuita…")
        let (stream, streamResponse) = try await session.bytes(from: callURL.appendingPathComponent(eventID))
        try requireSuccess(streamResponse)
        var event = "", payload: Data?, count = 0
        for try await line in stream.lines {
            try Task.checkCancellation()
            count += line.utf8.count
            guard count <= 1_000_000 else { throw Failure.message("Resposta da GPU excedeu o limite.") }
            if line.hasPrefix("event: ") { event = String(line.dropFirst(7)) }
            if event == "error" { throw Failure.message("A GPU gratuita não concluiu o pedido. A cota pode ter acabado; tente mais tarde ou use o iPhone.") }
            if event == "complete", line.hasPrefix("data: ") {
                payload = Data(line.dropFirst(6).utf8); break
            }
        }
        guard let payload else { throw Failure.message("A conexão com a GPU foi interrompida.") }
        let urls: [URL]
        let expected: Manifest?
        if community {
            urls = try communityCompletion(payload, space: space); expected = nil
        } else {
            let result = try completion(payload, space: space, sourceHash: digest)
            urls = result.0; expected = result.1
        }
        var hashes: [String: String] = [:]
        for (index, item) in names.enumerated() {
            progress(0.6 + Double(index) * 0.09, "Baixando stems \(index + 1)/4…")
            let (temporary, response) = try await session.download(from: urls[index])
            defer { try? FileManager.default.removeItem(at: temporary) }
            try requireSuccess(response)
            let byteCount = try temporary.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            let checksum = try hash(temporary)
            let maximumFrames = expected?.frames ?? Int64((seconds * 44_100).rounded())
            guard byteCount <= maximumFrames * 8 + 1_000_000,
                  expected == nil || checksum == expected?.sha256[item.1] else {
                throw Failure.message("Um stem chegou incompleto. Tente novamente mais tarde.")
            }
            hashes[item.1] = checksum
            try FileManager.default.moveItem(at: temporary, to: stage.appendingPathComponent(item.1 + ".wav"))
        }
        let result = asset(stage, model: admission.model)
        let frames = try NeuralStemWorker.validate(result, expectedSeconds: seconds)
        if let expected, frames != expected.frames { throw NeuralStemError.invalidOutput }
        let manifest = Manifest(model: admission.model, source_hash: digest, frames: frames,
                                sample_rate: 44_100, sha256: hashes)
        try JSONEncoder().encode(manifest).write(to: stage.appendingPathComponent("complete.json"), options: .atomic)
        try Task.checkCancellation()
        if FileManager.default.fileExists(atPath: folder.path) { try FileManager.default.removeItem(at: folder) }
        try FileManager.default.moveItem(at: stage, to: folder)
        progress(1, "Stems reais salvos para usar offline")
        return asset(folder, model: admission.model)
    }
}
