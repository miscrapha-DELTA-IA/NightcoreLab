import Foundation
import Security

/// Development bearer token is retained in iOS Keychain, not UserDefaults.
enum StemDevCredentials {
    private static let service = "com.nightcorelab.dev-stems"
    private static let account = "bearer-token"

    static func normalized(_ token: String) -> String {
        token.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func load() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8).map(normalized)
    }

    static func save(_ token: String) {
        let cleanToken = normalized(token)
        let identity: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(identity as CFDictionary)
        guard !cleanToken.isEmpty else { return }
        var attributes = identity
        attributes[kSecValueData as String] = Data(cleanToken.utf8)
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(attributes as CFDictionary, nil)
    }
}
