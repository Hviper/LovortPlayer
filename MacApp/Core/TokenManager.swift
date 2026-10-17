import Foundation
import AppKit
import Combine
import Security
import Darwin

@MainActor
public final class TokenManager: ObservableObject {
    public static let shared = TokenManager()

    @Published public private(set) var token: String = ""
    @Published public var isRevealed: Bool = false
    @Published public var hasCopiedFeedback: Bool = false

    public let tokenFileURL: URL

    public init(tokenFileURL: URL = ResourceLocator.defaultTokenFileURL) {
        self.tokenFileURL = tokenFileURL
        reloadToken()
    }

    /// Reads the token from disk if it exists.
    public func reloadToken() {
        let fm = FileManager.default
        let path = tokenFileURL.path
        guard fm.fileExists(atPath: path) else {
            token = ""
            return
        }

        do {
            let content = try String(contentsOf: tokenFileURL, encoding: .utf8)
            token = content.trimmingCharacters(in: .whitespacesAndNewlines)
            if !token.isEmpty {
                LogStore.shared.updateKnownSecrets([token])
            }
        } catch {
            token = ""
        }
    }

    /// Generates a new secure token and writes it with 0600 permissions if none exists.
    public func generateTokenIfNeeded() -> String? {
        if !token.isEmpty { return token }

        let parentDir = tokenFileURL.deletingLastPathComponent()
        let fm = FileManager.default

        do {
            try fm.createDirectory(at: parentDir, withIntermediateDirectories: true, attributes: [
                .posixPermissions: 0o700
            ])
            var bytes = [UInt8](repeating: 0, count: 32)
            let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
            guard status == errSecSuccess else { return nil }

            let newToken = Data(bytes).base64EncodedString()
                .replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_")
                .trimmingCharacters(in: CharacterSet(charactersIn: "="))

            let path = tokenFileURL.path
            let fd = open(path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
            if fd >= 0 {
                let fileHandle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
                if let data = newToken.data(using: .utf8) {
                    fileHandle.write(data)
                }
            } else {
                // If already created by another process, reload
                reloadToken()
                return token
            }

            reloadToken()
            return token
        } catch {
            return nil
        }
    }

    /// Returns masked string (e.g. ••••••••••••••••)
    public var maskedDisplay: String {
        guard !token.isEmpty else { return "尚未生成（启动服务后自动生成）" }
        return SecretRedactor.maskSecret(token)
    }

    /// Copies token to system pasteboard without logging.
    public func copyToPasteboard() {
        guard !token.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(token, forType: .string)
        hasCopiedFeedback = true

        Task {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            self.hasCopiedFeedback = false
        }
    }
}
