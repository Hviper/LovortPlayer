import Foundation
import Security

public enum SubtitleTranslationProviderType: String, CaseIterable, Codable, Identifiable, Sendable {
    case apple
    case openAI
    case deepL
    case google
    case azure

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .apple: return "Apple 设备端翻译"
        case .openAI: return "GPT 影视语境翻译"
        case .deepL: return "DeepL API"
        case .google: return "Google Cloud Translation"
        case .azure: return "Azure Translator"
        }
    }

    public var detail: String {
        switch self {
        case .apple: return "语言包下载后可完全离线，隐私和稳定性最好"
        case .openAI: return "擅长人物关系、俚语、敬语和上下文一致性"
        case .deepL: return "速度快，适合稳定的常规字幕翻译"
        case .google: return "语言覆盖广，适合多语种影视"
        case .azure: return "支持批量翻译、语言检测与企业区域端点"
        }
    }

    public var requiresAPIKey: Bool { self != .apple && self != .openAI }
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

    public func value(for provider: SubtitleTranslationProviderType) -> String {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: provider.rawValue,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return "" }
        return String(decoding: data, as: UTF8.self)
    }

    public func setValue(_ value: String, for provider: SubtitleTranslationProviderType) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: provider.rawValue
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

    public func translate(
        lines: [SubtitleLine],
        sourceLanguage: SubtitleSourceLanguage,
        targetLanguage: String,
        onProgress: (@Sendable (String) -> Void)?
    ) async throws -> [SubtitleLine] {
        try await CloudAISubtitleService(apiKey: token).translate(
            lines: lines,
            targetLanguage: targetLanguage,
            onProgress: onProgress
        )
    }
}

public struct RESTTranslationProvider: SubtitleTranslationProviding {
    public let provider: SubtitleTranslationProviderType
    public let apiKey: String
    public let azureRegion: String

    public init(provider: SubtitleTranslationProviderType, apiKey: String, azureRegion: String = "") {
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
        let (data, response) = try await URLSession(configuration: configuration).data(for: request)
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
