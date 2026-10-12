import Foundation
import CryptoKit
import LocalAuthentication

public final class VaultManager: @unchecked Sendable {
    public static let shared = VaultManager()
    
    private let keyTag = "com.lovortplayer.vault.masterkey"
    private var isUnlocked = false
    
    private init() {}

    public func authenticateWithBiometrics() async -> (success: Bool, error: String?) {
        let context = LAContext()
        var error: NSError?
        
        guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error) else {
            return (false, error?.localizedDescription ?? "Biometrics unavailable")
        }
        
        do {
            let success = try await context.evaluatePolicy(
                .deviceOwnerAuthenticationWithBiometrics,
                localizedReason: "解锁隐藏视频隐私保险箱"
            )
            self.isUnlocked = success
            return (success, nil)
        } catch {
            return (false, error.localizedDescription)
        }
    }
    
    public func encryptFile(at sourceURL: URL, destinationURL: URL, key: SymmetricKey) throws {
        let fileData = try Data(contentsOf: sourceURL)
        let sealedBox = try AES.GCM.seal(fileData, using: key)
        guard let combined = sealedBox.combined else {
            throw NSError(domain: "VaultError", code: -1, userInfo: [NSLocalizedDescriptionKey: "Encryption failed"])
        }
        try combined.write(to: destinationURL)
    }

    public func decryptFile(at sourceURL: URL, destinationURL: URL, key: SymmetricKey) throws {
        let encryptedData = try Data(contentsOf: sourceURL)
        let sealedBox = try AES.GCM.SealedBox(combined: encryptedData)
        let decryptedData = try AES.GCM.open(sealedBox, using: key)
        try decryptedData.write(to: destinationURL)
    }
    
    public func getOrCreateMasterKey() -> SymmetricKey {
        // Simplified key derivation / retrieval
        return SymmetricKey(size: .bits256)
    }
}
