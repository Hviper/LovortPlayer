import Foundation
import Security

public enum AuthProvider: String, Codable, Sendable {
    case chatgpt
    case antigravity
}

public final class AuthManager: @unchecked Sendable {
    public static let shared = AuthManager()

    private let keychainService = "com.lovortplayer.keys"

    private init() {}

    // MARK: - API Key Management
    public func saveAPIKey(_ key: String, for provider: AuthProvider) {
        let data = Data(key.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: provider.rawValue,
            kSecValueData as String: data
        ]
        SecItemDelete(query as CFDictionary)
        SecItemAdd(query as CFDictionary, nil)
    }

    public func getAPIKey(for provider: AuthProvider) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: provider.rawValue,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    // MARK: - OAuth Flow (PKCE)
    public func performOAuthLogin(provider: AuthProvider) async throws -> String {
        // ASWebAuthenticationSession PKCE OAuth implementation
        return "oauth_token_placeholder"
    }
}
