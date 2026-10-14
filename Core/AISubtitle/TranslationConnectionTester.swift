import Foundation

/// A snapshot of the editor drafts. Testing does not save credentials or change the active service.
public struct TranslationConnectionConfiguration: Sendable, Equatable {
    public var settings: TranslationAPISettings
    public var apiKey: String
    public var azureRegion: String = ""
    public var accessCredentials = VolcengineAccessCredentials(accessKeyID: "", secretAccessKey: "")
    public var openAIModel: String = ""

    public init(settings: TranslationAPISettings, apiKey: String, azureRegion: String = "",
                accessCredentials: VolcengineAccessCredentials = .init(accessKeyID: "", secretAccessKey: ""),
                openAIModel: String = "") {
        self.settings = settings
        self.apiKey = apiKey
        self.azureRegion = azureRegion
        self.accessCredentials = accessCredentials
        self.openAIModel = openAIModel
    }
}

public enum TranslationConnectionTester {
    public static func test(_ configuration: TranslationConnectionConfiguration, session: URLSession? = nil) async throws -> String {
        try Task.checkCancellation()
        let settings = configuration.settings
        let key = configuration.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let networkConfiguration = URLSessionConfiguration.ephemeral
        networkConfiguration.timeoutIntervalForRequest = 30
        networkConfiguration.timeoutIntervalForResource = 45
        let testSession = session ?? URLSession(configuration: networkConfiguration)
        defer { if session == nil { testSession.invalidateAndCancel() } }
        let service: any SubtitleTranslationProviding
        if settings.provider == .openAI {
            guard key.hasPrefix("sk-") else { throw failure("请填写 OpenAI Platform API Key（sk- 开头）") }
            guard !configuration.openAIModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw failure("请先选择 GPT 模型")
            }
            // The Cloud service retains the same proxy settings as real GPT requests.
            return try await CloudAISubtitleService(apiKey: key, session: session).testConnection(model: configuration.openAIModel)
        } else if settings.provider == .volcengine && settings.authenticationMode == .accessKey {
            try VolcengineAccessKeyTranslationProvider.validate(credentials: configuration.accessCredentials, endpointID: settings.model)
            service = VolcengineAccessKeyTranslationProvider(settings: settings, credentials: configuration.accessCredentials, session: testSession)
        } else {
            guard settings.provider != .apple else { throw failure("系统翻译无需 API 连接测试") }
            guard !key.isEmpty else { throw failure("请先填写 API Key，测试不会回退到系统翻译") }
            if settings.provider.usesChatCompletions {
                service = ChatCompletionTranslationProvider(settings: settings, apiKey: key, session: testSession)
            } else {
                service = RESTTranslationProvider(provider: settings.provider, apiKey: key, azureRegion: configuration.azureRegion, session: testSession)
            }
        }
        let result = try await service.translate(
            lines: [SubtitleLine(startTime: 0, endTime: 1, originalText: "Hello.")],
            sourceLanguage: .english, targetLanguage: "简体中文", onProgress: nil)
        try Task.checkCancellation()
        guard result.count == 1, let value = result.first?.translatedText,
              !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw failure("服务未返回有效翻译，请检查模型或接口格式")
        }
        return value
    }

    /// Never display a server body: it can contain credentials, request headers or arbitrary text.
    public static func errorMessage(_ error: Error) -> String {
        let error = error as NSError
        if error.domain == NSURLErrorDomain {
            return error.code == NSURLErrorTimedOut ? "请求超时，请检查网络、代理或服务状态" : "网络连接失败，请检查网络、代理和服务地址"
        }
        if error.domain == "TranslationConnectionTest" || error.domain == "TranslationConfiguration" {
            return error.localizedDescription
        }
        let status = error.domain == "OpenAIServiceError" ? error.code : httpStatus(in: error.localizedDescription)
        switch status {
        case 401, 403: return "鉴权失败（HTTP \(status)），请检查密钥和调用权限"
        case 404: return "服务或模型不存在（HTTP 404），请检查地址、模型或接入点 ID"
        case 429: return "请求受限（HTTP 429），请检查余额、配额或稍后重试"
        case 500...599: return "服务暂时不可用（HTTP \(status)），请稍后重试"
        default: return "测试失败，请检查密钥、模型、接入点 ID 和返回格式"
        }
    }

    private static func httpStatus(in message: String) -> Int {
        guard let range = message.range(of: "HTTP ") else { return -1 }
        return Int(message[range.upperBound...].prefix(3)) ?? -1
    }

    private static func failure(_ message: String) -> NSError {
        NSError(domain: "TranslationConnectionTest", code: -1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
