import CryptoKit
import Foundation
import Security

public enum SubtitleTranslationProviderType: String, CaseIterable, Codable, Identifiable, Sendable {
    case apple
    case openAI
    case deepL
    case google
    case azure
    case zhipu
    case volcengine
    case volcengineMachineTranslation
    case customChat

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .apple: return "Apple 设备端翻译"
        case .openAI: return "GPT 影视语境翻译"
        case .deepL: return "DeepL API"
        case .google: return "Google Cloud Translation"
        case .azure: return "Azure Translator"
        case .zhipu: return "智谱 AI"
        case .volcengine: return "火山方舟 AI 翻译"
        case .volcengineMachineTranslation: return "火山机器翻译"
        case .customChat: return "自定义兼容 API"
        }
    }

    public var detail: String {
        switch self {
        case .apple: return "语言包下载后可完全离线，隐私和稳定性最好"
        case .openAI: return "擅长人物关系、俚语、敬语和上下文一致性"
        case .deepL: return "速度快，适合稳定的常规字幕翻译"
        case .google: return "语言覆盖广，适合多语种影视"
        case .azure: return "支持批量翻译、语言检测与企业区域端点"
        case .zhipu: return "官方地址已内置，填写 API Key 即可使用预设模型"
        case .volcengine: return "官方地址已内置，支持 API Key 或 AK / SK 鉴权"
        case .volcengineMachineTranslation: return "火山引擎文本翻译 API，只需 AK / SK，无需模型或接入点"
        case .customChat: return "配置 URL、API Key 和模型，使用 Chat Completions 翻译"
        }
    }

    public var usesChatCompletions: Bool { [.zhipu, .volcengine, .customChat].contains(self) }

    public var requiresAPIKey: Bool { self != .apple && self != .openAI && self != .volcengineMachineTranslation }
}

public protocol SubtitleTranslationProviding: Sendable {
    func translate(
        lines: [SubtitleLine],
        sourceLanguage: SubtitleSourceLanguage,
        targetLanguage: String,
        onProgress: (@Sendable (String) -> Void)?
    ) async throws -> [SubtitleLine]
}

public struct TranslationCredentialStore: Sendable {
    public static let shared = TranslationCredentialStore()
    private let service = "com.hviper.lovortplayer.translation-provider"

    public func value(for provider: SubtitleTranslationProviderType, field: String = "apiKey") -> String {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: field == "apiKey" ? provider.rawValue : "\(provider.rawValue).\(field)",
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return "" }
        return String(decoding: data, as: UTF8.self)
    }

    public func setValue(_ value: String, for provider: SubtitleTranslationProviderType, field: String = "apiKey") {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: field == "apiKey" ? provider.rawValue : "\(provider.rawValue).\(field)"
        ]
        SecItemDelete(query as CFDictionary)
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var item = query
        item[kSecValueData as String] = Data(trimmed.utf8)
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(item as CFDictionary, nil)
    }
}

public struct OpenAITranslationProvider: SubtitleTranslationProviding {
    let token: String
    let model: String?

    public init(token: String, model: String? = nil) {
        self.token = token
        self.model = model
    }

    public func translate(
        lines: [SubtitleLine],
        sourceLanguage: SubtitleSourceLanguage,
        targetLanguage: String,
        onProgress: (@Sendable (String) -> Void)?
    ) async throws -> [SubtitleLine] {
        try await CloudAISubtitleService(apiKey: token, textModel: model).translate(
            lines: lines,
            targetLanguage: targetLanguage,
            onProgress: onProgress
        )
    }
}

public enum OpenAITextChannel: String, Codable, Sendable {
    case platformAPI
    case chatGPTSubscription
}

public struct OpenAITranslationExecutionConfiguration: Codable, Equatable, Sendable {
    public let channel: OpenAITextChannel
    public let model: String
    public let credentialFingerprint: String?

    public init(channel: OpenAITextChannel, model: String, credentialFingerprint: String?) {
        self.channel = channel
        self.model = model.trimmingCharacters(in: .whitespacesAndNewlines)
        self.credentialFingerprint = credentialFingerprint
    }

    public var cacheIdentity: String {
        "openAI|\(channel.rawValue)|\(model)|\(credentialFingerprint ?? "unconfigured")"
    }

    public static func fingerprint(_ value: String) -> String? {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }
        return SHA256.hash(data: Data(value.utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
    }
}

public struct ChatGPTSubscriptionTranslationProvider: SubtitleTranslationProviding {
    public typealias TokenProvider = @Sendable (_ forceRefresh: Bool) async throws -> String

    private let tokenProvider: TokenProvider
    let model: String
    private let session: URLSession

    public init(tokenProvider: @escaping TokenProvider, model: String, session: URLSession? = nil) {
        self.tokenProvider = tokenProvider
        self.model = model.trimmingCharacters(in: .whitespacesAndNewlines)
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.default
            configuration.timeoutIntervalForRequest = 90
            configuration.timeoutIntervalForResource = 600
            let host = UserDefaults.standard.string(forKey: "LovortCustomProxyHost") ?? ""
            let port = UserDefaults.standard.integer(forKey: "LovortCustomProxyPort")
            if !host.isEmpty, port > 0 {
                configuration.connectionProxyDictionary = [
                    "HTTPEnable": 1, "HTTPProxy": host, "HTTPPort": port,
                    "HTTPSEnable": 1, "HTTPSProxy": host, "HTTPSPort": port
                ]
            }
            self.session = URLSession(configuration: configuration)
        }
    }

    public func translate(
        lines: [SubtitleLine],
        sourceLanguage: SubtitleSourceLanguage,
        targetLanguage: String,
        onProgress: (@Sendable (String) -> Void)?
    ) async throws -> [SubtitleLine] {
        try await transform(
            lines: lines,
            text: { $0.originalText },
            targetLanguage: targetLanguage,
            progressLabel: "ChatGPT 订阅正在翻译",
            instructions: "You are a professional audiovisual subtitle translator. Preserve character voice, relationships, honorifics, slang, and context.",
            onProgress: onProgress
        )
    }

    public func polish(
        lines: [SubtitleLine],
        targetLanguage: String,
        onProgress: (@Sendable (String) -> Void)?
    ) async throws -> [SubtitleLine] {
        try await transform(
            lines: lines,
            text: { $0.translatedText ?? $0.originalText },
            targetLanguage: targetLanguage,
            progressLabel: "ChatGPT 订阅正在精修",
            instructions: "You are a professional subtitle editor. Polish the translated subtitles for consistent names, honorifics, slang, character voice, and natural audiovisual timing without changing meaning.",
            onProgress: onProgress
        )
    }

    private func transform(
        lines: [SubtitleLine],
        text: (SubtitleLine) -> String,
        targetLanguage: String,
        progressLabel: String,
        instructions: String,
        onProgress: (@Sendable (String) -> Void)?
    ) async throws -> [SubtitleLine] {
        guard !lines.isEmpty else { return [] }
        var translated: [UUID: String] = [:]
        let batches = stride(from: 0, to: lines.count, by: 24).map {
            Array(lines[$0..<min($0 + 24, lines.count)])
        }
        for (batchIndex, batch) in batches.enumerated() {
            try Task.checkCancellation()
            onProgress?("\(progressLabel) \(batchIndex + 1)/\(batches.count)…")
            let input = batch.enumerated().map {
                ["index": $0.offset, "text": text($0.element)] as [String: Any]
            }
            let inputJSON = String(decoding: try JSONSerialization.data(withJSONObject: input), as: UTF8.self)
            let prompt = """
            将以下影视字幕处理为“\(targetLanguage)”。必须保留全部条目，不得合并、拆分或省略。
            只返回严格 JSON 数组，不要 Markdown。每项格式为 {"index": 原索引, "translation": "结果"}，必须覆盖 0 到 \(batch.count - 1)。
            输入：\(inputJSON)
            """
            let values = try await request(prompt: prompt, instructions: instructions,
                                           expectedCount: batch.count)
            for (line, value) in zip(batch, values) { translated[line.id] = value }
        }
        return lines.map { line in
            SubtitleLine(id: line.id, startTime: line.startTime, endTime: line.endTime,
                         originalText: line.originalText,
                         translatedText: translated[line.id] ?? line.translatedText)
        }
    }

    private func request(prompt: String, instructions: String, expectedCount: Int) async throws -> [String] {
        guard let endpoint = URL(string: "https://chatgpt.com/backend-api/codex/responses") else {
            throw URLError(.badURL)
        }
        guard !model.isEmpty else { throw subscriptionError("请先选择 ChatGPT 模型") }
        var forceRefresh = false
        for attempt in 0..<2 {
            let token = try await tokenProvider(forceRefresh)
            let trimmedToken = token.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedToken.isEmpty else { throw subscriptionError("请先登录 ChatGPT 订阅账户") }
            var request = URLRequest(url: endpoint)
            request.httpMethod = "POST"
            request.setValue("Bearer \(trimmedToken)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("responses=experimental", forHTTPHeaderField: "OpenAI-Beta")
            if let accountID = Self.accountID(from: trimmedToken) {
                request.setValue(accountID, forHTTPHeaderField: "chatgpt-account-id")
            }
            request.httpBody = try JSONSerialization.data(withJSONObject: [
                "model": model,
                "instructions": instructions,
                "input": [["role": "user", "content": [["type": "input_text", "text": prompt]]]],
                "store": false
            ])
            let (data, response) = try await session.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            if status == 401, attempt == 0 {
                forceRefresh = true
                continue
            }
            guard (200...299).contains(status) else {
                throw NSError(domain: "ChatGPTSubscription", code: status,
                              userInfo: [NSLocalizedDescriptionKey: Self.statusMessage(status)])
            }
            let content = try Self.responseText(from: data)
            return try CloudAISubtitleService.decodeTranslations(from: content, expectedCount: expectedCount)
        }
        throw subscriptionError("ChatGPT 登录已失效，请重新登录")
    }

    static func accountID(from token: String) -> String? {
        let parts = token.split(separator: ".")
        guard parts.count == 3 else { return nil }
        var value = String(parts[1]).replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while value.count % 4 != 0 { value += "=" }
        guard let data = Data(base64Encoded: value),
              let claims = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let auth = claims["https://api.openai.com/auth"] as? [String: Any] else { return nil }
        return auth["chatgpt_account_id"] as? String
    }

    private static func responseText(from data: Data) throws -> String {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw subscriptionError("ChatGPT 返回格式无效")
        }
        if let text = root["output_text"] as? String, !text.isEmpty { return text }
        for item in root["output"] as? [[String: Any]] ?? [] {
            for content in item["content"] as? [[String: Any]] ?? [] {
                if let text = content["text"] as? String, !text.isEmpty { return text }
            }
        }
        throw subscriptionError("ChatGPT 未返回有效字幕文本")
    }

    private static func statusMessage(_ status: Int) -> String {
        switch status {
        case 401: return "ChatGPT 登录已失效，请重新登录"
        case 403: return "当前 ChatGPT 账户未授权订阅模型能力"
        case 429: return "ChatGPT 订阅额度暂时受限，请稍后重试"
        default: return "ChatGPT 订阅请求失败（HTTP \(status)）"
        }
    }

    private static func subscriptionError(_ message: String) -> NSError {
        NSError(domain: "ChatGPTSubscription", code: -1,
                userInfo: [NSLocalizedDescriptionKey: message])
    }

    private func subscriptionError(_ message: String) -> NSError { Self.subscriptionError(message) }
}

public struct RESTTranslationProvider: SubtitleTranslationProviding {
    public let provider: SubtitleTranslationProviderType
    public let apiKey: String
    public let azureRegion: String
    private let session: URLSession?

    public init(provider: SubtitleTranslationProviderType, apiKey: String, azureRegion: String = "", session: URLSession? = nil) {
        self.session = session
        self.provider = provider
        self.apiKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        self.azureRegion = azureRegion.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public func translate(
        lines: [SubtitleLine],
        sourceLanguage: SubtitleSourceLanguage,
        targetLanguage: String,
        onProgress: (@Sendable (String) -> Void)?
    ) async throws -> [SubtitleLine] {
        guard !apiKey.isEmpty else { throw providerError("请先填写 \(provider.displayName) 的 API Key") }
        var translated: [UUID: String] = [:]
        let batches = stride(from: 0, to: lines.count, by: 40).map {
            Array(lines[$0..<min($0 + 40, lines.count)])
        }
        for (index, batch) in batches.enumerated() {
            try Task.checkCancellation()
            onProgress?("正在使用 \(provider.displayName) 翻译 \(index + 1)/\(batches.count)...")
            let values: [String]
            switch provider {
            case .deepL:
                values = try await translateWithDeepL(batch, source: sourceLanguage, target: targetLanguage)
            case .google:
                values = try await translateWithGoogle(batch, source: sourceLanguage, target: targetLanguage)
            case .azure:
                values = try await translateWithAzure(batch, source: sourceLanguage, target: targetLanguage)
            default:
                throw providerError("翻译 Provider 配置无效")
            }
            guard values.count == batch.count else { throw providerError("翻译结果数量与原字幕不一致") }
            for (line, value) in zip(batch, values) { translated[line.id] = value }
        }
        return lines.map { line in
            SubtitleLine(
                id: line.id,
                startTime: line.startTime,
                endTime: line.endTime,
                originalText: line.originalText,
                translatedText: translated[line.id]
            )
        }
    }

    private func translateWithDeepL(
        _ lines: [SubtitleLine],
        source: SubtitleSourceLanguage,
        target: String
    ) async throws -> [String] {
        let host = apiKey.hasSuffix(":fx") ? "api-free.deepl.com" : "api.deepl.com"
        var request = URLRequest(url: URL(string: "https://\(host)/v2/translate")!)
        request.httpMethod = "POST"
        request.setValue("DeepL-Auth-Key \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var body: [String: Any] = [
            "text": lines.map(\.originalText),
            "target_lang": targetCode(target, style: .deepL)
        ]
        if let sourceCode = sourceCode(source, style: .deepL) { body["source_lang"] = sourceCode }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let data = try await perform(request)
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = root["translations"] as? [[String: Any]] else { throw providerError("DeepL 返回格式无效") }
        return items.compactMap { $0["text"] as? String }
    }

    private func translateWithGoogle(
        _ lines: [SubtitleLine],
        source: SubtitleSourceLanguage,
        target: String
    ) async throws -> [String] {
        var components = URLComponents(string: "https://translation.googleapis.com/language/translate/v2")!
        components.queryItems = [URLQueryItem(name: "key", value: apiKey)]
        var request = URLRequest(url: components.url!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var body: [String: Any] = [
            "q": lines.map(\.originalText),
            "target": targetCode(target, style: .google),
            "format": "text"
        ]
        if let sourceCode = sourceCode(source, style: .google) { body["source"] = sourceCode }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let data = try await perform(request)
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let dataObject = root["data"] as? [String: Any],
              let items = dataObject["translations"] as? [[String: Any]] else { throw providerError("Google 翻译返回格式无效") }
        return items.compactMap { ($0["translatedText"] as? String)?.decodedHTMLEntities }
    }

    private func translateWithAzure(
        _ lines: [SubtitleLine],
        source: SubtitleSourceLanguage,
        target: String
    ) async throws -> [String] {
        var components = URLComponents(string: "https://api.cognitive.microsofttranslator.com/translate")!
        var query = [
            URLQueryItem(name: "api-version", value: "3.0"),
            URLQueryItem(name: "to", value: targetCode(target, style: .azure))
        ]
        if let sourceCode = sourceCode(source, style: .azure) { query.append(URLQueryItem(name: "from", value: sourceCode)) }
        components.queryItems = query
        var request = URLRequest(url: components.url!)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "Ocp-Apim-Subscription-Key")
        if !azureRegion.isEmpty { request.setValue(azureRegion, forHTTPHeaderField: "Ocp-Apim-Subscription-Region") }
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: lines.map { ["Text": $0.originalText] })
        let data = try await perform(request)
        guard let items = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { throw providerError("Azure 翻译返回格式无效") }
        return items.compactMap { item in
            (item["translations"] as? [[String: Any]])?.first?["text"] as? String
        }
    }

    private func perform(_ request: URLRequest) async throws -> Data {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 90
        configuration.timeoutIntervalForResource = 600
        let (data, response) = try await (session ?? URLSession(configuration: configuration)).data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            let responseText = String(decoding: data.prefix(500), as: UTF8.self)
            throw providerError("\(provider.displayName) 请求失败（HTTP \(status)）：\(responseText)")
        }
        return data
    }

    private enum CodeStyle { case deepL, google, azure }

    private func sourceCode(_ language: SubtitleSourceLanguage, style: CodeStyle) -> String? {
        guard language != .automatic else { return nil }
        switch (language, style) {
        case (.japanese, .deepL): return "JA"
        case (.english, .deepL): return "EN"
        case (.chinese, .deepL): return "ZH"
        case (.korean, .deepL): return "KO"
        case (.japanese, _): return "ja"
        case (.english, _): return "en"
        case (.chinese, _): return "zh"
        case (.korean, _): return "ko"
        case (.automatic, _): return nil
        }
    }

    private func targetCode(_ language: String, style: CodeStyle) -> String {
        if language.contains("繁") { return style == .deepL ? "ZH-HANT" : style == .azure ? "zh-Hant" : "zh-TW" }
        if language.contains("英") { return style == .deepL ? "EN-US" : "en" }
        return style == .deepL ? "ZH-HANS" : style == .azure ? "zh-Hans" : "zh-CN"
    }

    private func providerError(_ message: String) -> NSError {
        NSError(domain: "SubtitleTranslationProvider", code: -1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}

private extension String {
    var decodedHTMLEntities: String {
        replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&amp;", with: "&")
    }
}

/// Non-secret configuration lives in defaults; credentials stay in Keychain.
public struct TranslationAPISettings: Sendable, Equatable {
    public let provider: SubtitleTranslationProviderType
    public var url: String
    public var model: String
    public var authenticationMode: VolcengineAuthenticationMode

    public init(provider: SubtitleTranslationProviderType, defaults: UserDefaults = .standard) {
        self.provider = provider
        let prefix = "LovortTranslation.\(provider.rawValue)."
        let preset: String
        switch provider {
        case .zhipu: preset = "https://open.bigmodel.cn/api/paas/v4"
        case .volcengine: preset = "https://ark.cn-beijing.volces.com/api/v3"
        default: preset = ""
        }
        url = provider == .customChat ? (defaults.string(forKey: prefix + "url") ?? "") : preset
        let savedModel = defaults.string(forKey: prefix + "model") ?? ""
        let defaultModel = provider == .zhipu ? "glm-4-flash-250414"
            : provider == .volcengine ? "doubao-seed-2-0-mini-260428" : ""
        model = savedModel.isEmpty ? defaultModel : savedModel
        authenticationMode = provider == .volcengine
            ? (VolcengineAuthenticationMode(rawValue: defaults.string(forKey: prefix + "authMode") ?? "") ?? .apiKey)
            : .apiKey
    }

    public func save(defaults: UserDefaults = .standard) {
        let prefix = "LovortTranslation.\(provider.rawValue)."
        if provider == .customChat {
            defaults.set(url.trimmingCharacters(in: .whitespacesAndNewlines), forKey: prefix + "url")
        }
        if provider == .volcengine { defaults.set(authenticationMode.rawValue, forKey: prefix + "authMode") }
        defaults.set(model.trimmingCharacters(in: .whitespacesAndNewlines), forKey: prefix + "model")
    }

    public func endpoint() throws -> URL {
        let baseURL: String
        switch provider {
        case .zhipu: baseURL = "https://open.bigmodel.cn/api/paas/v4"
        case .volcengine: baseURL = "https://ark.cn-beijing.volces.com/api/v3"
        default: baseURL = url.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard var components = URLComponents(string: baseURL),
              components.scheme == "https", let host = components.host, !host.isEmpty,
              components.user == nil, components.password == nil,
              components.query == nil, components.fragment == nil else {
            throw NSError(domain: "TranslationConfiguration", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "请填写有效的 HTTPS API 地址（不含账号、查询参数或片段）"])
        }
        var path = components.path
        while path.hasSuffix("/") { path.removeLast() }
        if !path.hasSuffix("/chat/completions") { path += "/chat/completions" }
        components.path = path
        guard let endpoint = components.url else { throw URLError(.badURL) }
        return endpoint
    }

    public var usesAccessKeyCredentials: Bool {
        provider == .volcengineMachineTranslation || (provider == .volcengine && authenticationMode == .accessKey)
    }

    public var cacheIdentity: String? {
        if provider == .volcengineMachineTranslation { return "volcengineMachineTranslation|TranslateText|2020-06-01" }
        return provider.usesChatCompletions ? "\(provider.rawValue)|\((try? endpoint().absoluteString) ?? url)|\(model)|\(authenticationMode.rawValue)" : nil
    }

    public static func effectiveProvider(_ provider: SubtitleTranslationProviderType, hasCredential: Bool) -> SubtitleTranslationProviderType {
        provider != .apple && provider != .openAI && !hasCredential ? .apple : provider
    }

    public func effectiveCacheIdentity(
        openAIConfiguration: OpenAITranslationExecutionConfiguration?,
        enhanceWithGPT: Bool
    ) -> String? {
        if provider == .openAI {
            return openAIConfiguration?.cacheIdentity ?? "openAI|unconfigured"
        }
        guard enhanceWithGPT else { return cacheIdentity }
        return "\(cacheIdentity ?? provider.rawValue)|gpt-polish|\(openAIConfiguration?.cacheIdentity ?? "openAI|unconfigured")"
    }
}

public struct ChatCompletionTranslationProvider: SubtitleTranslationProviding {
    public let settings: TranslationAPISettings
    public let apiKey: String
    private let session: URLSession

    public init(settings: TranslationAPISettings, apiKey: String, session: URLSession? = nil) {
        self.settings = settings
        self.apiKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 90
        self.session = session ?? URLSession(configuration: configuration)
    }

    public func translate(lines: [SubtitleLine], sourceLanguage: SubtitleSourceLanguage,
                          targetLanguage: String, onProgress: (@Sendable (String) -> Void)?) async throws -> [SubtitleLine] {
        guard !lines.isEmpty else { return [] }
        let endpoint = try settings.endpoint()
        let model = settings.model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !apiKey.isEmpty, !model.isEmpty else {
            throw NSError(domain: "TranslationConfiguration", code: -2,
                          userInfo: [NSLocalizedDescriptionKey: "请在翻译 API 管理中填写 API Key 和模型 ID（火山可填写接入点 ID）"])
        }
        var result = lines
        let batchSize = 24
        let total = (lines.count + batchSize - 1) / batchSize
        for start in stride(from: 0, to: lines.count, by: batchSize) {
            try Task.checkCancellation()
            let end = min(start + batchSize, lines.count)
            onProgress?("正在使用 \(settings.provider.displayName) 翻译 \(start / batchSize + 1)/\(total)...")
            let input = lines[start..<end].enumerated().map { ["index": $0.offset, "text": $0.element.originalText] as [String: Any] }
            let json = String(decoding: try JSONSerialization.data(withJSONObject: input), as: UTF8.self)
            var request = URLRequest(url: endpoint)
            request.httpMethod = "POST"
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: [
                "model": model, "stream": false,
                "messages": [
                    ["role": "system", "content": "你是影视字幕译者。将用户提供的台词翻译为\(targetLanguage)，保留每一条，结合上下文处理称谓和语气。只返回 JSON 数组，每项包含 index 和非空 translation，不要 Markdown。"],
                    ["role": "user", "content": json]
                ]
            ])
            let (data, response) = try await session.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            guard (200...299).contains(status) else {
                // Do not echo server payloads which may contain credentials or subtitle text.
                throw NSError(domain: "TranslationAPI", code: status,
                              userInfo: [NSLocalizedDescriptionKey: "\(settings.provider.displayName) 请求失败（HTTP \(status)），请检查地址、Key、模型和额度"])
            }
            guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let choices = root["choices"] as? [[String: Any]],
                  let message = choices.first?["message"] as? [String: Any],
                  let content = message["content"] as? String else {
                throw NSError(domain: "TranslationAPI", code: -3,
                              userInfo: [NSLocalizedDescriptionKey: "API 未返回有效的 Chat Completions 文本"])
            }
            let values = try CloudAISubtitleService.decodeTranslations(from: content, expectedCount: end - start)
            for (offset, value) in values.enumerated() {
                let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else {
                    throw NSError(domain: "TranslationAPI", code: -4,
                                  userInfo: [NSLocalizedDescriptionKey: "API 返回空译文，已保留原文字幕"])
                }
                let line = lines[start + offset]
                result[start + offset] = SubtitleLine(id: line.id, startTime: line.startTime,
                    endTime: line.endTime, originalText: line.originalText, translatedText: text)
            }
        }
        return result
    }
}
