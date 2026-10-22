import Foundation
import Security

/// A personal read token belongs to this installation, never to the Render API.
enum HuggingFaceAccess {
    private final class NoRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        func urlSession(_ session: URLSession, task: URLSessionTask,
                        willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest,
                        completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
    }
    private static let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: "com.nightcorelab.huggingface", kSecAttrAccount as String: "read-token"]
    static func read() -> String {
        var request = query; request[kSecReturnData as String] = true
        var result: CFTypeRef?
        guard SecItemCopyMatching(request as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return "" }
        return String(data: data, encoding: .utf8) ?? ""
    }
    static func save(_ value: String) -> Bool {
        let token = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if token.isEmpty {
            let status = SecItemDelete(query as CFDictionary)
            return status == errSecSuccess || status == errSecItemNotFound
        }
        let data = Data(token.utf8)
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecSuccess { return true }
        guard status == errSecItemNotFound else { return false }
        var request = query; request[kSecValueData as String] = data
        request[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(request as CFDictionary, nil) == errSecSuccess
    }
    struct Profile: Equatable {
        let name: String
    }
    static func freeProfile(_ data: Data) throws -> Profile {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let name = object["name"] as? String, !name.isEmpty,
              let pro = object["isPro"] as? Bool, !pro,
              let auth = object["auth"] as? [String: Any],
              let access = auth["accessToken"] as? [String: Any],
              access["role"] as? String == "read" else {
            throw CloudStemWorker.Failure.message("Use uma conta gratuita e um token pessoal somente de leitura (Read). Contas PRO e tokens de escrita não são usados nesta integração gratuita.")
        }
        return Profile(name: name)
    }
    static func verify(_ token: String, session: URLSession) async throws -> Profile {
        guard token.hasPrefix("hf_"), token.count >= 16, !token.contains(where: { $0.isWhitespace }) else {
            throw CloudStemWorker.Failure.message("Token do Hugging Face inválido. Crie um token Read nas configurações da sua conta.")
        }
        var request = URLRequest(url: URL(string: "https://huggingface.co/api/whoami-v2")!)
        request.timeoutInterval = 30
        request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200, data.count <= 200_000,
              http.url?.host == "huggingface.co" else {
            throw CloudStemWorker.Failure.message("Não foi possível autenticar no Hugging Face. Confira o token Read e a conexão.")
        }
        return try freeProfile(data)
    }
    static func verify(_ token: String) async throws -> Profile {
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil
        let session = URLSession(configuration: config, delegate: NoRedirects(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        return try await verify(token, session: session)
    }
    /// Exact pinned community origin only. Never attach a personal token to Render,
    /// arbitrary provider URLs or redirects supplied in a remote response.
    static func authorize(_ request: URLRequest, token: String) throws -> URLRequest {
        guard !token.isEmpty else { return request }
        guard let url = request.url, url.scheme == "https",
              url.host == CloudStemWorker.communityURL.host,
              url.port == nil, url.user == nil, url.password == nil else {
            throw CloudStemWorker.Failure.message("O token pessoal só pode ser enviado ao Space de GPU autorizado.")
        }
        var result = request
        result.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        return result
    }
}
