import Foundation
import CryptoKit
import LocalAuthentication
import Security
import CommonCrypto
import Combine

public struct BackupVaultSecrets: Codable, Sendable {
    public let masterKey: Data?
    public let pinRecord: Data?
    public init(masterKey: Data?, pinRecord: Data?) {
        self.masterKey = masterKey
        self.pinRecord = pinRecord
    }
}

@MainActor
public final class VaultManager: ObservableObject {
    public static let shared = VaultManager()
    @Published public private(set) var isUnlocked = false
    public private(set) var isDecoyMode = false
    private let keyTag = "com.lovortplayer.vault.masterkey"
    private let pinTag = "com.lovortplayer.vault.pin.v2"
    private var failures = UserDefaults.standard.integer(forKey: "vault.failedAttempts") {
        didSet { UserDefaults.standard.set(failures, forKey: "vault.failedAttempts") }
    }
    private var blockedUntil = Date(timeIntervalSince1970: UserDefaults.standard.double(forKey: "vault.blockedUntil")) {
        didSet { UserDefaults.standard.set(blockedUntil.timeIntervalSince1970, forKey: "vault.blockedUntil") }
    }
    private var session = UUID()
    private var readableFiles: Set<URL> = []
    private let readableDirectory: URL
    private init() {
        readableDirectory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("VaultReadable", isDirectory: true)
        // Files left by a terminated process have no living consumers.
        try? FileManager.default.removeItem(at: readableDirectory)
    }
    public var hasPassword: Bool { readKeychain(pinTag) != nil }
    public var retryAfter: Int { max(0, Int(ceil(blockedUntil.timeIntervalSinceNow))) }
    public func setPassword(_ pin: String) async throws {
        let token = session
        if !hasPassword {
            let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent(".Vault")
            let hasExistingFiles = !((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []).isEmpty
            if hasExistingFiles || readKeychain(keyTag) != nil {
                let context = LAContext()
                guard try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: "验证设备身份，为已有保险箱设置新密码") else { throw error("身份验证未完成") }
                guard token == session else { throw error("保险箱设置已取消") }
            }
        }
        guard !hasPassword || isUnlocked else { throw error("请先解锁保险箱再修改密码") }
        guard pin.count >= 6, pin.count <= 12, pin.allSatisfy({ $0.isASCII && $0.isNumber }) else { throw error("请使用 6–12 位数字密码") }
        var salt = Data(count: 16)
        let status = salt.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 16, $0.baseAddress!) }
        guard status == errSecSuccess else { throw error("无法生成密码盐") }
        try writeKeychain(pinTag, data: salt + derivePIN(pin, salt: salt))
        UserDefaults.standard.removeObject(forKey: "LovortVaultRealPassword")
        UserDefaults.standard.removeObject(forKey: "LovortVaultDecoyPassword")
        failures = 0
        blockedUntil = .distantPast
    }
    private func derivePIN(_ pin: String, salt: Data) -> Data {
        var result = Data(count: 32)
        let bytes = Array(pin.utf8)
        _ = bytes.withUnsafeBytes { password in
            salt.withUnsafeBytes { saltBytes in
                result.withUnsafeMutableBytes { output in
                    CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2), password.baseAddress!.assumingMemoryBound(to: Int8.self), bytes.count,
                        saltBytes.baseAddress!.assumingMemoryBound(to: UInt8.self), salt.count, CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), 100_000,
                        output.baseAddress!.assumingMemoryBound(to: UInt8.self), 32)
                }
            }
        }
        return result
    }
    public func verifyPassword(_ pin: String) -> (success: Bool, isDecoy: Bool) {
        guard pin.count >= 6, pin.count <= 12, pin.allSatisfy({ $0.isASCII && $0.isNumber }), Date() >= blockedUntil, let record = readKeychain(pinTag), record.count == 48 else { return (false, false) }
        let derived = derivePIN(pin, salt: record.prefix(16))
        let difference = zip(derived, record.suffix(32)).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) }
        if difference == 0 {
            isUnlocked = true
            failures = 0
            Task { await MediaLibraryManager.shared.migrateLegacyVaultFiles() }
            return (true, false)
        }
        failures += 1
        if failures >= 5 { blockedUntil = Date().addingTimeInterval(30); failures = 0 }
        return (false, false)
    }
    public func authenticateWithBiometrics() async -> (success: Bool, error: String?) {
        guard hasPassword else { return (false, "请先设置保险箱密码") }
        let token = session
        let context = LAContext()
        context.localizedCancelTitle = "取消"
        do {
            let success = try await context.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, localizedReason: "解锁私密视频保险箱")
            guard token == session else { return (false, "验证已取消") }
            isUnlocked = success
            if success {
                Task { await MediaLibraryManager.shared.migrateLegacyVaultFiles() }
            }
            return (success, nil)
        } catch { return (false, error.localizedDescription) }
    }
    public func lockVault() {
        SubtitleTaskManager.shared.pausePrivateTasks()
        session = UUID()
        isUnlocked = false
        isDecoyMode = false
        Self.removeReadableFiles(readableFiles, directory: readableDirectory)
        readableFiles.removeAll()
        Task { await ThumbnailStore.shared.clearMemoryOnly() }
    }
    static func removeReadableFiles(_ files: Set<URL>, directory: URL) {
        for file in files { try? FileManager.default.removeItem(at: file) }
        try? FileManager.default.removeItem(at: directory)
    }
    public func exportBackupSecrets() throws -> BackupVaultSecrets {
        guard !hasPassword || isUnlocked else { throw error("请先解锁保险箱再备份") }
        return BackupVaultSecrets(masterKey: readKeychain(keyTag), pinRecord: readKeychain(pinTag))
    }
    public func restoreBackupSecrets(_ secrets: BackupVaultSecrets) throws {
        guard readKeychain(keyTag) == nil, readKeychain(pinTag) == nil else { throw error("此设备已有保险箱，不能覆盖其密钥") }
        guard (secrets.masterKey == nil) == (secrets.pinRecord == nil) else { throw error("备份中的保险箱凭据不完整") }
        guard secrets.masterKey == nil || secrets.masterKey?.count == 32,
              secrets.pinRecord == nil || secrets.pinRecord?.count == 48 else { throw error("备份中的保险箱凭据无效") }
        if let key = secrets.masterKey { try writeKeychain(keyTag, data: key) }
        do {
            if let pin = secrets.pinRecord { try writeKeychain(pinTag, data: pin) }
        } catch {
            if secrets.masterKey != nil {
                SecItemDelete([kSecClass: kSecClassGenericPassword, kSecAttrAccount: keyTag] as CFDictionary)
            }
            throw error
        }
    }
    public func encryptFile(at source: URL, destinationURL destination: URL, progress: (@Sendable (Double) -> Void)? = nil) async throws {
        guard hasPassword else { throw error("请先设置保险箱密码") }
        let key = try masterKey()
        let task = Task.detached(priority: .userInitiated) { try VaultFileCryptor.encrypt(source: source, destination: destination, key: key, progress: progress) }
        try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }
    public func decryptFile(at source: URL, destinationURL destination: URL, progress: (@Sendable (Double) -> Void)? = nil) async throws {
        guard isUnlocked else { throw error("请先解锁保险箱") }
        let key = try masterKey()
        let task = Task.detached(priority: .userInitiated) { try VaultFileCryptor.decrypt(source: source, destination: destination, key: key, progress: progress) }
        try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }
    public func readableURL(for url: URL) async throws -> URL {
        guard url.pathExtension.lowercased() == "vault" || url.path.contains("/.Vault/") else { return url }
        guard isUnlocked else { throw error("请先解锁保险箱") }
        guard url.pathExtension.lowercased() == "vault" else { return url }
        let token = session
        try FileManager.default.createDirectory(at: readableDirectory, withIntermediateDirectories: true)
        #if os(iOS)
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: readableDirectory.path)
        #endif
        let output = readableDirectory.appendingPathComponent(UUID().uuidString + "-" + url.deletingPathExtension().lastPathComponent)
        do {
            try await decryptFile(at: url, destinationURL: output)
            try Task.checkCancellation()
            guard token == session, isUnlocked else { throw error("保险箱已锁定") }
            readableFiles.insert(output)
            return output
        } catch { try? FileManager.default.removeItem(at: output); throw error }
    }
    public func releaseReadableURL(_ url: URL) {
        guard readableFiles.remove(url) != nil else { return }
        try? FileManager.default.removeItem(at: url)
    }
    private func masterKey() throws -> SymmetricKey {
        if let data = readKeychain(keyTag) { return SymmetricKey(data: data) }
        let key = SymmetricKey(size: .bits256)
        try writeKeychain(keyTag, data: key.withUnsafeBytes { Data($0) })
        return key
    }
    private func readKeychain(_ account: String) -> Data? {
        var item: CFTypeRef?
        let status = SecItemCopyMatching([kSecClass: kSecClassGenericPassword, kSecAttrAccount: account,
            kSecReturnData: true, kSecMatchLimit: kSecMatchLimitOne] as CFDictionary, &item)
        return status == errSecSuccess ? item as? Data : nil
    }
    private func writeKeychain(_ account: String, data: Data) throws {
        let query = [kSecClass: kSecClassGenericPassword, kSecAttrAccount: account] as CFDictionary
        let status: OSStatus
        if readKeychain(account) != nil { status = SecItemUpdate(query, [kSecValueData: data] as CFDictionary) }
        else { status = SecItemAdd([kSecClass: kSecClassGenericPassword, kSecAttrAccount: account, kSecValueData: data,
                                   kSecAttrAccessible: kSecAttrAccessibleWhenUnlocked] as CFDictionary, nil) }
        guard status == errSecSuccess else { throw error("无法安全保存保险箱凭据，请解锁设备后重试") }
    }
    private func error(_ text: String) -> NSError { NSError(domain: "Vault", code: 1, userInfo: [NSLocalizedDescriptionKey: text]) }
}
