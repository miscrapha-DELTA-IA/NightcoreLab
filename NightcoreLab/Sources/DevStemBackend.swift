import AVFoundation
import Foundation

/// Explicitly opted-in DEV integration: POST local compressed audio to an
/// authenticated htdemucs worker, then download its four independent WAVs.
/// Disabled by default. The production app never uploads audio automatically.
enum DevStemBackend {
    private struct Job: Decodable {
        let id: String
        let status: String
        let message: String?
    }

    static var enabled: Bool { UserDefaults.standard.bool(forKey: "stems.devBackendEnabled") }

    static func endpoint() -> URL? {
        guard enabled,
              let raw = UserDefaults.standard.string(forKey: "stems.devBackendURL"),
              let url = URL(string: raw), let host = url.host,
              url.scheme == "https" || (url.scheme == "http" &&
                     ["localhost", "127.0.0.1"].contains(host)),
              url.user == nil, url.password == nil else { return nil }
        return url
    }

    static func separate(source: URL, cacheFolder: URL, server: URL) async throws -> StemAsset {
        guard let size = (try? source.resourceValues(forKeys: [.fileSizeKey])).flatMap(\.fileSize),
              size > 0, size <= 35 * 1024 * 1024 else {
            throw URLError(.dataLengthExceedsMaximum)
        }
        let token = UserDefaults.standard.string(forKey: "stems.devBackendToken") ?? ""
        guard token.count >= 16 else { throw URLError(.userAuthenticationRequired) }
        var request = URLRequest(url: server.appendingPathComponent("api/stems"))
        request.httpMethod = "POST"
        request.timeoutInterval = 90
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        let (responseData, response) = try await URLSession.shared.upload(for: request, fromFile: source)
        guard let http = response as? HTTPURLResponse, http.statusCode == 202 else {
            throw URLError(.badServerResponse)
        }
        let job = try JSONDecoder().decode(Job.self, from: responseData)
        guard !job.id.isEmpty, job.id.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" }) else {
            throw URLError(.cannotParseResponse)
        }
        let jobURL = server.appendingPathComponent("api/stems").appendingPathComponent(job.id)
        var ready = false
        for _ in 0..<120 {
            try Task.checkCancellation()
            var polling = URLRequest(url: jobURL)
            polling.timeoutInterval = 20
            polling.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
            let (data, reply) = try await URLSession.shared.data(for: polling)
            guard (reply as? HTTPURLResponse)?.statusCode == 200 else {
                throw URLError(.badServerResponse)
            }
            let result = try JSONDecoder().decode(Job.self, from: data)
            if result.status == "ready" { ready = true; break }
            if result.status == "failed" { throw URLError(.cannotDecodeContentData) }
            try await Task.sleep(for: .seconds(3))
        }
        guard ready else { throw URLError(.timedOut) }
        let folder = cacheFolder.appendingPathComponent("demucs-" + job.id, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var paths: [StemKind: URL] = [:]
        let remoteNames: [StemKind: String] = [
            .vocal: "vocals", .instrumental: "other", .drums: "drums", .bass: "bass"
        ]
        do {
            var duration: Double?
            for kind in StemKind.allCases {
                try Task.checkCancellation()
                let name = remoteNames[kind]!
                var fetch = URLRequest(url: jobURL.appendingPathComponent(name))
                fetch.timeoutInterval = 180
                fetch.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
                let (temporary, response) = try await URLSession.shared.download(for: fetch)
                guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                    throw URLError(.badServerResponse)
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
