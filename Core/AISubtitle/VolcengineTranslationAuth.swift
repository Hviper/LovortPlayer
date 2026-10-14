import CryptoKit
import Foundation

public enum VolcengineAuthenticationMode: String, CaseIterable, Sendable, Identifiable {
    case apiKey
    case accessKey
    public var id: String { rawValue }
    public var displayName: String { self == .apiKey ? "API Key" : "Access Key ID / Secret Access Key" }
}

public struct VolcengineAccessCredentials: Sendable {
    public let accessKeyID: String
    public let secretAccessKey: String
    public init(accessKeyID: String, secretAccessKey: String) {
        self.accessKeyID = accessKeyID.trimmingCharacters(in: .whitespacesAndNewlines)
        self.secretAccessKey = secretAccessKey.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    public var isEmpty: Bool { accessKeyID.isEmpty && secretAccessKey.isEmpty }
    public var isComplete: Bool { !accessKeyID.isEmpty && !secretAccessKey.isEmpty }
    public static func saved() -> Self {
        let store = TranslationCredentialStore.shared
        return Self(accessKeyID: store.value(for: .volcengine, field: "accessKeyID"),
                    secretAccessKey: store.value(for: .volcengine, field: "secretAccessKey"))
    }
    public func save() {
        let store = TranslationCredentialStore.shared
        store.setValue(accessKeyID, for: .volcengine, field: "accessKeyID")
        store.setValue(secretAccessKey, for: .volcengine, field: "secretAccessKey")
    }
}

/// Uses AK/SK to obtain an endpoint-scoped temporary API key, as the official Ark SDK does.
public struct VolcengineAccessKeyTranslationProvider: SubtitleTranslationProviding {
    public let settings: TranslationAPISettings
    public let credentials: VolcengineAccessCredentials
    private let session: URLSession

    public init(settings: TranslationAPISettings, credentials: VolcengineAccessCredentials, session: URLSession? = nil) {
        self.settings = settings
        self.credentials = credentials
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 90
        self.session = session ?? URLSession(configuration: configuration)
    }

    public func translate(lines: [SubtitleLine], sourceLanguage: SubtitleSourceLanguage,
                          targetLanguage: String, onProgress: (@Sendable (String) -> Void)?) async throws -> [SubtitleLine] {
        guard !lines.isEmpty else { return [] }
        try Task.checkCancellation()
        guard settings.provider == .volcengine else { throw Self.authError("AK / SK 仅用于火山方舟官方服务") }
        onProgress?("正在使用火山方舟 AK / SK 获取临时翻译凭证...")
        let request = try Self.temporaryKeyRequest(credentials: credentials, endpointID: settings.model)
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard (200...299).contains(status),
              let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let result = root["Result"] as? [String: Any],
              let key = result["ApiKey"] as? String, !key.isEmpty else {
            throw Self.authError("火山 AK / SK 鉴权失败（HTTP \(status)），请检查密钥、IAM 权限和接入点 ID")
        }
        // The temporary token lives only in this task; never persist or log it.
        return try await ChatCompletionTranslationProvider(settings: settings, apiKey: key, session: session)
            .translate(lines: lines, sourceLanguage: sourceLanguage, targetLanguage: targetLanguage, onProgress: onProgress)
    }

    static func temporaryKeyRequest(credentials: VolcengineAccessCredentials, endpointID: String,
                                    date: Date = Date()) throws -> URLRequest {
        try validate(credentials: credentials, endpointID: endpointID)
        let endpoint = endpointID.trimmingCharacters(in: .whitespacesAndNewlines)
        var request = URLRequest(url: URL(string: "https://ark.cn-beijing.volcengineapi.com/?Action=GetApiKey&Version=2024-01-01")!)
        request.timeoutInterval = 30
        request.httpMethod = "POST"
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "DurationSeconds": 86_400, "ResourceType": "endpoint", "ResourceIds": [endpoint]
        ], options: [.sortedKeys, .withoutEscapingSlashes])
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        let timestamp = formatter.string(from: date)
        let bodyHash = hex(SHA256.hash(data: request.httpBody!))
        let host = "ark.cn-beijing.volcengineapi.com"
        let signedHeaders = "content-type;host;x-content-sha256;x-date"
        let canonicalHeaders = "content-type:application/json\nhost:\(host)\nx-content-sha256:\(bodyHash)\nx-date:\(timestamp)\n"
        let canonical = ["POST", "/", "Action=GetApiKey&Version=2024-01-01", canonicalHeaders, signedHeaders, bodyHash].joined(separator: "\n")
        let day = String(timestamp.prefix(8))
        let scope = "\(day)/cn-beijing/ark/request"
        let toSign = ["HMAC-SHA256", timestamp, scope, hex(SHA256.hash(data: Data(canonical.utf8)))].joined(separator: "\n")
        var signingKey = Data(credentials.secretAccessKey.utf8)
        for value in [day, "cn-beijing", "ark", "request"] { signingKey = hmac(key: signingKey, text: value) }
        let signature = hex(hmac(key: signingKey, text: toSign))
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(host, forHTTPHeaderField: "Host")
        request.setValue(timestamp, forHTTPHeaderField: "X-Date")
        request.setValue(bodyHash, forHTTPHeaderField: "X-Content-Sha256")
        request.setValue("HMAC-SHA256 Credential=\(credentials.accessKeyID)/\(scope), SignedHeaders=\(signedHeaders), Signature=\(signature)", forHTTPHeaderField: "Authorization")
        return request
    }

    public static func validate(credentials: VolcengineAccessCredentials, endpointID: String) throws {
        guard credentials.isComplete else { throw authError("请填写完整的 Access Key ID 和 Secret Access Key") }
        let endpoint = endpointID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard endpoint.hasPrefix("ep-"), endpoint.count > 3 else {
            throw authError("AK / SK 鉴权需要接入点 ID（ep- 开头），不能填写通用模型名称")
        }
    }

    private static func hmac(key: Data, text: String) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: Data(text.utf8), using: SymmetricKey(data: key)))
    }
    private static func hex<T: Sequence>(_ bytes: T) -> String where T.Element == UInt8 {
        bytes.map { String(format: "%02x", $0) }.joined()
    }
    private static func authError(_ message: String) -> NSError {
        NSError(domain: "VolcengineTranslationAuth", code: -1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
