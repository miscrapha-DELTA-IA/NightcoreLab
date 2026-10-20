import Foundation
import Security

/// Tokens são fornecidos individualmente aos testadores; nunca fazem parte do app ou do Git.
enum ServerAccessTokenStore {
    private static let service = "gnarly.beta.access-token"

    private static func account(for serverURL: String) -> String? {
        guard let url = URLComponents(string: serverURL),
              let scheme = url.scheme?.lowercased(),
              let host = url.host?.lowercased(),
              ["https", "http"].contains(scheme) else { return nil }
        return "\(scheme)://\(host):\(url.port ?? (scheme == "https" ? 443 : 80))"
    }

    private static func query(for serverURL: String) -> [String: Any]? {
        guard let account = account(for: serverURL) else { return nil }
        return [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }

    static func load(for serverURL: String) -> String {
        guard var query = query(for: serverURL) else { return "" }
        query[kSecReturnData as String] = kCFBooleanTrue
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data,
              let token = String(data: data, encoding: .utf8) else { return "" }
        return token
    }

    @discardableResult
    static func save(_ token: String, for serverURL: String) -> Bool {
        guard let query = query(for: serverURL) else { return false }
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            let status = SecItemDelete(query as CFDictionary)
            return status == errSecSuccess || status == errSecItemNotFound
        }
        let bytes = Data(trimmed.utf8)
        let result = SecItemUpdate(query as CFDictionary, [kSecValueData as String: bytes] as CFDictionary)
        if result == errSecSuccess { return true }
        guard result == errSecItemNotFound else { return false }
        var addition = query
        addition[kSecValueData as String] = bytes
        addition[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(addition as CFDictionary, nil) == errSecSuccess
    }
}
