import Foundation
import Security
import AuthenticationServices

public enum AuthProvider: String, Codable, Sendable {
    case chatgpt
    case antigravity
}

public struct UserAuthProfile: Codable, Sendable {
    public var provider: AuthProvider
    public var username: String
    public var quotaRemaining: String
    public var isLoggedIn: Bool
}

@MainActor
public final class AuthManager: ObservableObject {
    public static let shared = AuthManager()

    private let keychainService = "com.lovortplayer.keys"
    private let profileKey = "LovortUserProfileData"

    @Published public var currentProfile: UserAuthProfile?

    private init() {
        loadProfile()
    }

    private func loadProfile() {
        if let data = UserDefaults.standard.data(forKey: profileKey),
           let profile = try? JSONDecoder().decode(UserAuthProfile.self, from: data) {
            self.currentProfile = profile
        }
    }

    private func saveProfile(_ profile: UserAuthProfile?) {
        self.currentProfile = profile
        if let profile = profile, let data = try? JSONEncoder().encode(profile) {
            UserDefaults.standard.set(data, forKey: profileKey)
        } else {
            UserDefaults.standard.removeObject(forKey: profileKey)
        }
    }

    // MARK: - API Key 管理
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

    // MARK: - 模拟/真实 OAuth 登录打通
    public func loginWithProvider(_ provider: AuthProvider) async -> Bool {
        // 模拟 OAuth 握手并授权解锁额度
        try? await Task.sleep(nanoseconds: 800_000_000)
        let profile = UserAuthProfile(
            provider: provider,
            username: provider == .chatgpt ? "OpenAI Plus 订阅用户" : "Antigravity 开发者账户",
            quotaRemaining: "无限次 AI 字幕转录与翻译",
            isLoggedIn: true
        )
        saveProfile(profile)
        return true
    }

    public func logout() {
        saveProfile(nil)
    }
}
