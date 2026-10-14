import Foundation

/// Fire-and-return text translation API; no chat model, endpoint ID or temporary Ark token.
public struct VolcengineMachineTranslationProvider: SubtitleTranslationProviding {
    public let credentials: VolcengineAccessCredentials
    private let session: URLSession
    static let endpoint = URL(string: "https://translate.volcengineapi.com/?Action=TranslateText&Version=2020-06-01")!

    public init(credentials: VolcengineAccessCredentials, session: URLSession? = nil) {
        self.credentials = credentials
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 45
        self.session = session ?? URLSession(configuration: configuration)
    }

    public func translate(lines: [SubtitleLine], sourceLanguage: SubtitleSourceLanguage,
                          targetLanguage: String, onProgress: (@Sendable (String) -> Void)?) async throws -> [SubtitleLine] {
        guard !lines.isEmpty else { return [] }
        guard credentials.isComplete else { throw Self.error("请填写完整的 Access Key ID 和 Secret Access Key") }
        let batches = try Self.batches(lines)
        var output: [SubtitleLine] = []
        for (index, batch) in batches.enumerated() {
            try Task.checkCancellation()
            onProgress?("正在使用火山机器翻译 \(index + 1)/\(batches.count)…")
            let request = try Self.translationRequest(credentials: credentials, lines: batch,
                                                      source: sourceLanguage, target: targetLanguage)
            let (data, response) = try await session.data(for: request)
            try Task.checkCancellation()
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            guard (200...299).contains(status) else {
                throw Self.error("火山机器翻译请求失败（HTTP \(status)），请检查 AK/SK、权限和服务状态", code: status)
            }
            guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw Self.error("火山机器翻译返回格式无效")
            }
            if let metadata = root["ResponseMetadata"] as? [String: Any],
               let apiError = metadata["Error"] as? [String: Any] {
                // Never echo API Message or arbitrary Code; both can contain sensitive request data.
                let code = String(describing: apiError["Code"] ?? "")
                let hint: String
                switch code {
                case "InvalidAccessKey", "InvalidAccessKeyId", "SignatureDoesNotMatch", "AccessDenied", "Forbidden":
                    hint = "鉴权失败，请检查 AK/SK、设备时间和机器翻译调用权限"
                case "-429", "429", "TooManyRequests", "Throttling": hint = "请求受限，请检查配额或稍后重试"
                case "-415": hint = "不支持所选翻译语向"
                default: hint = "调用失败，请确认已开通机器翻译服务、账户余额和调用权限"
                }
                throw Self.error("火山机器翻译\(hint)")
            }
            guard let translations = root["TranslationList"] as? [[String: Any]], translations.count == batch.count else {
                throw Self.error("火山机器翻译返回条数与字幕不一致")
            }
            for (line, item) in zip(batch, translations) {
                guard let text = item["Translation"] as? String,
                      !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw Self.error("火山机器翻译返回空译文")
                }
                output.append(SubtitleLine(id: line.id, startTime: line.startTime, endTime: line.endTime,
                                           originalText: line.originalText, translatedText: text))
            }
        }
        return output
    }

    /// UTF-16 counts conservatively enforce the 5000-character limit, including emoji.
    static func batches(_ lines: [SubtitleLine]) throws -> [[SubtitleLine]] {
        var result: [[SubtitleLine]] = []
        var current: [SubtitleLine] = []
        var length = 0
        for line in lines {
            let count = line.originalText.utf16.count
            guard count <= 5_000 else { throw error("单条字幕超过火山机器翻译 5000 字符限制，请先拆分字幕") }
            if current.count == 16 || length + count > 5_000 {
                result.append(current)
                current = []
                length = 0
            }
            current.append(line)
            length += count
        }
        if !current.isEmpty { result.append(current) }
        return result
    }

    static func translationRequest(credentials: VolcengineAccessCredentials, lines: [SubtitleLine],
                                   source: SubtitleSourceLanguage, target: String, date: Date = Date()) throws -> URLRequest {
        guard credentials.isComplete else { throw error("请填写完整的 Access Key ID 和 Secret Access Key") }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        var body: [String: Any] = ["TargetLanguage": try targetCode(target), "TextList": lines.map(\.originalText)]
        if let sourceCode = source.whisperCode { body["SourceLanguage"] = sourceCode }
        request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys, .withoutEscapingSlashes])
        return VolcengineRequestSigner.sign(request, credentials: credentials, region: "cn-north-1", service: "translate", date: date)
    }

    static func targetCode(_ language: String) throws -> String {
        if language.contains("繁体") || language.contains("繁體") || language == "zh-Hant" { return "zh-Hant" }
        if language.contains("简体") || language.contains("中文") || ["zh", "zh-CN", "zh-Hans"].contains(language) { return "zh" }
        if language.contains("日") || language == "ja" { return "ja" }
        if language.contains("韩") || language == "ko" { return "ko" }
        if language.contains("英") || language == "en" { return "en" }
        throw error("火山机器翻译不支持当前目标语言配置")
    }

    private static func error(_ message: String, code: Int = -1) -> NSError {
        NSError(domain: "VolcengineMachineTranslation", code: code, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
