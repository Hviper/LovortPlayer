import Foundation
import CryptoKit
import LocalAuthentication
import Security

public final class VaultManager: @unchecked Sendable {
    public static let shared = VaultManager()

    private let keyTag = "com.lovortplayer.vault.masterkey"
    public private(set) var isUnlocked = false
    public private(set) var isDecoyMode = false // 诱导假密码模式

    private let realPasswordKey = "LovortVaultRealPassword"
    private let decoyPasswordKey = "LovortVaultDecoyPassword"

    private init() {}

    /// 生物识别（Face ID / Touch ID）解锁
    public func authenticateWithBiometrics() async -> (success: Bool, error: String?) {
        let context = LAContext()
        context.localizedCancelTitle = "取消"
        var error: NSError?

        guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error) else {
            return (false, error?.localizedDescription ?? "设备未开启生物识别")
        }

        do {
            let success = try await context.evaluatePolicy(
                .deviceOwnerAuthenticationWithBiometrics,
                localizedReason: "解锁私密视频保险箱"
            )
            self.isUnlocked = success
            self.isDecoyMode = false
            return (success, nil)
        } catch {
            return (false, error.localizedDescription)
        }
    }

    /// 数字密码验证（包含真密码与诱导假密码）
    public func verifyPassword(_ pin: String) -> (success: Bool, isDecoy: Bool) {
        let savedReal = UserDefaults.standard.string(forKey: realPasswordKey) ?? "1234"
        let savedDecoy = UserDefaults.standard.string(forKey: decoyPasswordKey) ?? "0000"

        if pin == savedReal {
            self.isUnlocked = true
            self.isDecoyMode = false
            return (true, false)
        } else if pin == savedDecoy {
            // 进入反侦察虚假空间：显示解锁成功，但实际上过滤出空列表或假视频
            self.isUnlocked = true
            self.isDecoyMode = true
            return (true, true)
        } else {
            return (false, false)
        }
    }

    /// 锁定保险箱
    public func lockVault() {
        self.isUnlocked = false
        self.isDecoyMode = false
    }

    // MARK: - AES-256 GCM 磁盘物理加密
    public func encryptFile(at sourceURL: URL, destinationURL: URL) throws {
        let key = getOrCreateMasterKey()
        let fileData = try Data(contentsOf: sourceURL)
        let sealedBox = try AES.GCM.seal(fileData, using: key)
        guard let combined = sealedBox.combined else {
            throw NSError(domain: "VaultError", code: -1, userInfo: [NSLocalizedDescriptionKey: "AES-256 加密封装失败"])
        }
        try combined.write(to: destinationURL)
    }

    public func decryptFile(at sourceURL: URL, destinationURL: URL) throws {
        let key = getOrCreateMasterKey()
        let encryptedData = try Data(contentsOf: sourceURL)
        let sealedBox = try AES.GCM.SealedBox(combined: encryptedData)
        let decryptedData = try AES.GCM.open(sealedBox, using: key)
        try decryptedData.write(to: destinationURL)
    }

    public func decryptToTemporaryPlaybackURL(encryptedURL: URL) throws -> URL {
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + "_" + encryptedURL.deletingPathExtension().lastPathComponent)
        try decryptFile(at: encryptedURL, destinationURL: tempURL)
        return tempURL
    }

    public func getOrCreateMasterKey() -> SymmetricKey {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: keyTag,
            kSecReturnData as String: true
        ]
        var item: CFTypeRef?
        if SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
           let data = item as? Data {
            return SymmetricKey(data: data)
        }

        // 新建并安全存入 Keychain
        let newKey = SymmetricKey(size: .bits256)
        let keyData = newKey.withUnsafeBytes { Data($0) }
        let addQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: keyTag,
            kSecValueData as String: keyData
        ]
        SecItemAdd(addQuery as CFDictionary, nil)
        return newKey
    }
}
