import Foundation

/// Same JSON contract as the working OpenAI backend. Credentials stay on the server.
enum LyricsAlignmentClient {
    struct Request: Encodable { let url: String; let lyrics: String }
    struct Response: Decodable { let lrc: String }
    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    static func align(videoID: String, lyrics: String, baseURL: String,
                      session: URLSession = .shared) async throws -> String {
        guard let base = URL(string: baseURL) else {
            throw Failure(message: "Confira o endereço do servidor para sincronizar as palavras.")
        }
        var request = URLRequest(url: base.appendingPathComponent("align-lyrics"),
                                 timeoutInterval: 160)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(Request(
            url: "https://www.youtube.com/watch?v=\(videoID)", lyrics: lyrics))
        let (data, response) = try await session.data(for: request)
        try Task.checkCancellation()
        guard let http = response as? HTTPURLResponse else {
            throw Failure(message: "Resposta inválida ao sincronizar as palavras.")
        }
        guard http.statusCode == 200 else {
            let message: String
            switch http.statusCode {
            case 404: message = "Este servidor ainda não oferece sincronia com OpenAI."
            case 422: message = "Não foi possível confirmar a sincronia das palavras com este áudio."
            case 429: message = "Sincronia temporariamente ocupada ou limitada pelo YouTube."
            case 503: message = "Sincronia OpenAI indisponível no servidor."
            default: message = "Falha ao sincronizar as palavras (HTTP \(http.statusCode))."
            }
            throw Failure(message: message)
        }
        let result = try JSONDecoder().decode(Response.self, from: data)
        guard !result.lrc.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw Failure(message: "O servidor não encontrou palavras sincronizadas.")
        }
        return result.lrc
    }
}
