import Foundation

/// Pure-logic secret redactor ensuring sensitive tokens and credentials are never stored in logs.
public struct SecretRedactor: Sendable {
    private let knownSecrets: [String]

    public init(knownSecrets: [String] = []) {
        self.knownSecrets = knownSecrets.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    /// Redacts sensitive information from a raw line of log text.
    public func redact(_ line: String) -> String {
        var sanitized = line

        // 1. Redact explicit "Access token: <token>" output from server.py
        let tokenPrefixPattern = #"Access token:\s*([^\s\r\n]+)"#
        if let regex = try? NSRegularExpression(pattern: tokenPrefixPattern, options: [.caseInsensitive]) {
            let range = NSRange(location: 0, length: sanitized.utf16.count)
            sanitized = regex.stringByReplacingMatches(
                in: sanitized,
                options: [],
                range: range,
                withTemplate: "Access token: [已隐藏口令 / REDACTED]"
            )
        }

        // 2. Redact HTTP headers like X-Lovort-Token: <token>
        let headerPattern = #"X-Lovort-Token:\s*([^\s\r\n]+)"#
        if let regex = try? NSRegularExpression(pattern: headerPattern, options: [.caseInsensitive]) {
            let range = NSRange(location: 0, length: sanitized.utf16.count)
            sanitized = regex.stringByReplacingMatches(
                in: sanitized,
                options: [],
                range: range,
                withTemplate: "X-Lovort-Token: [REDACTED]"
            )
        }

        // 3. Redact standard bearer authorization headers
        let bearerPattern = #"Authorization:\s*Bearer\s+([^\s\r\n]+)"#
        if let regex = try? NSRegularExpression(pattern: bearerPattern, options: [.caseInsensitive]) {
            let range = NSRange(location: 0, length: sanitized.utf16.count)
            sanitized = regex.stringByReplacingMatches(
                in: sanitized,
                options: [],
                range: range,
                withTemplate: "Authorization: Bearer [REDACTED]"
            )
        }

        // 4. Redact common JSON credential values
        let jsonSecretPattern = #"(\"(?:token|access_token|api[_-]?key)\"\s*:\s*\")[^\"]*(\")"#
        if let regex = try? NSRegularExpression(pattern: jsonSecretPattern, options: [.caseInsensitive]) {
            let range = NSRange(location: 0, length: sanitized.utf16.count)
            sanitized = regex.stringByReplacingMatches(
                in: sanitized,
                options: [],
                range: range,
                withTemplate: "$1[REDACTED]$2"
            )
        }

        // 5. Redact query param token=xxx
        let queryTokenPattern = #"([?&]token=)([^&\s]+)"#
        if let regex = try? NSRegularExpression(pattern: queryTokenPattern, options: [.caseInsensitive]) {
            let range = NSRange(location: 0, length: sanitized.utf16.count)
            sanitized = regex.stringByReplacingMatches(
                in: sanitized,
                options: [],
                range: range,
                withTemplate: "$1[REDACTED]"
            )
        }

        // 6. Redact any known secret string directly
        for secret in knownSecrets {
            if !secret.isEmpty && sanitized.contains(secret) {
                sanitized = sanitized.replacingOccurrences(of: secret, with: "[REDACTED]")
            }
        }

        return sanitized
    }

    /// Formats a masked preview of a secret string, e.g. "••••••••" or "ab••...••yz".
    public static func maskSecret(_ secret: String) -> String {
        guard !secret.isEmpty else { return "无口令" }
        return String(repeating: "•", count: min(24, max(8, secret.count)))
    }
}
