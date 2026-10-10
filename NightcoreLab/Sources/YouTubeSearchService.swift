import Foundation

/// iOS cannot spawn yt-dlp. The existing Python bridge runs the CLI and returns NDJSON.
struct YouTubeSearchService {
    func search(query: String, serverURL: String) async throws -> [Track] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return [] }
        guard var components = URLComponents(string: serverURL) else { throw SearchError.invalidServer }
        components.path += "/search"
        components.queryItems = [URLQueryItem(name: "query", value: query)]
        guard let url = components.url else { throw SearchError.invalidServer }
        var request = URLRequest(url: url, timeoutInterval: 90)
        request.setValue("application/x-ndjson", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        try Task.checkCancellation()
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw SearchError.unavailable
        }
        return try Self.decode(data)
    }

    static func decode(_ data: Data) throws -> [Track] {
        guard let text = String(data: data, encoding: .utf8) else { throw SearchError.invalidResponse }
        var seen = Set<String>()
        return try text.split(whereSeparator: \.isNewline).compactMap { line -> Track? in
            let entry = try JSONDecoder().decode(Entry.self, from: Data(line.utf8))
            guard entry.id.range(of: "^[A-Za-z0-9_-]{11}$", options: .regularExpression) != nil,
                  !entry.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  entry.is_live != true,
                  !["private", "premium_only", "subscriber_only"].contains(entry.availability ?? ""),
                  seen.insert(entry.id).inserted else { return nil }
            let candidates = [entry.thumbnail] + (entry.thumbnails ?? []).reversed().map(\.url)
            let thumbnail = candidates.compactMap { $0 }.first { $0.scheme?.lowercased() == "https" }
            return Track(id: entry.id, title: entry.title,
                         thumbnailURL: thumbnail ?? URL(string: "https://i.ytimg.com/vi/\(entry.id)/hqdefault.jpg"))
        }.prefix(15).map { $0 }
    }

    private struct Entry: Decodable {
        let id: String
        let title: String
        let thumbnail: URL?
        let thumbnails: [Thumbnail]?
        let is_live: Bool?
        let availability: String?
    }
    private struct Thumbnail: Decodable { let url: URL? }

    enum SearchError: LocalizedError {
        case invalidServer, unavailable, invalidResponse
        var errorDescription: String? {
            switch self {
            case .invalidServer: return "Confira o endereço em Servidor."
            case .unavailable: return "Busca indisponível. Verifique o servidor e tente novamente."
            case .invalidResponse: return "O servidor enviou uma resposta de busca inválida."
            }
        }
    }
}
