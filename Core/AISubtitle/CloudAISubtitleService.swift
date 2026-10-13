import Foundation
import Speech

public final class CloudAISubtitleService: AISubtitleServiceProtocol, @unchecked Sendable {
    private let apiKey: String
    private let baseURL: URL

    public init(apiKey: String, baseURL: URL = URL(string: "https://api.openai.com/v1")!) {
        self.apiKey = apiKey
        self.baseURL = baseURL
    }

    /// 创建支持系统代理/Clash 代理与自定义 HTTP 代理的 URLSession
    private func createProxyAwareSession() -> URLSession {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 300

        // 检查用户是否自定义了本地代理（例如 127.0.0.1:7890）
        let proxyHost = UserDefaults.standard.string(forKey: "LovortCustomProxyHost") ?? ""
        let proxyPort = UserDefaults.standard.integer(forKey: "LovortCustomProxyPort")

        if !proxyHost.isEmpty && proxyPort > 0 {
            config.connectionProxyDictionary = [
                "HTTPEnable": 1,
                "HTTPProxy": proxyHost,
                "HTTPPort": proxyPort,
                "HTTPSEnable": 1,
                "HTTPSProxy": proxyHost,
                "HTTPSPort": proxyPort
            ]
        }
        return URLSession(configuration: config)
    }

    public func transcribeAndTranslate(audioURL: URL, targetLanguage: String = "zh") async throws -> [SubtitleLine] {
        var parsedLines: [SubtitleLine] = []

        // 1. 如果是 sk- 开头的 OpenAI Platform Key，优先走 Whisper API；如果是 ChatGPT OAuth 订阅 Token 或 Whisper 失败，走 iOS 原生语音识别提取时间轴文本
        if apiKey.hasPrefix("sk-"), let srtText = try? await requestWhisperTranscription(audioURL: audioURL) {
            parsedLines = SRTParser.parse(srtString: srtText)
        }

        if parsedLines.isEmpty {
            parsedLines = await transcribeWithAppleSpeech(audioURL: audioURL)
        }

        if parsedLines.isEmpty {
            return []
        }

        // 2. 将转录文字传给 GPT (支持 ChatGPT Plus/Pro OAuth 订阅通道与 API Key 通道) 做上下文翻译
        let translatedLines = try await requestTranslation(lines: parsedLines, targetLanguage: targetLanguage)
        return translatedLines
    }

    /// 使用 iOS 原生 Speech 框架识别提取出的 m4a 音轨（无需消耗 Whisper API 余额，配合 ChatGPT OAuth 翻译）
    private func transcribeWithAppleSpeech(audioURL: URL) async -> [SubtitleLine] {
        let authorized = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status == .authorized)
            }
        }
        guard authorized, let recognizer = SFSpeechRecognizer(), recognizer.isAvailable else {
            return []
        }

        let request = SFSpeechURLRecognitionRequest(url: audioURL)
        request.shouldReportPartialResults = false

        final class ResumeGate: @unchecked Sendable {
            var hasResumed = false
        }
        let gate = ResumeGate()

        return await withCheckedContinuation { continuation in
            recognizer.recognitionTask(with: request) { result, error in
                guard !gate.hasResumed else { return }
                if let result = result, result.isFinal {
                    gate.hasResumed = true
                    var lines: [SubtitleLine] = []
                    var currentText = ""
                    var chunkStart: TimeInterval = 0
                    var lastEnd: TimeInterval = 0

                    for segment in result.bestTranscription.segments {
                        if currentText.isEmpty {
                            chunkStart = segment.timestamp
                        }
                        currentText += (currentText.isEmpty ? "" : " ") + segment.substring
                        lastEnd = segment.timestamp + segment.duration

                        if currentText.count >= 36 || segment.substring.hasSuffix(".") || segment.substring.hasSuffix("?") || segment.substring.hasSuffix("!") || (lastEnd - chunkStart) >= 4.5 {
                            lines.append(
                                SubtitleLine(
                                    startTime: chunkStart,
                                    endTime: max(chunkStart + 1.2, lastEnd),
                                    originalText: currentText,
                                    translatedText: ""
                                )
                            )
                            currentText = ""
                        }
                    }
                    if !currentText.isEmpty {
                        lines.append(
                            SubtitleLine(
                                startTime: chunkStart,
                                endTime: max(chunkStart + 1.5, lastEnd),
                                originalText: currentText,
                                translatedText: ""
                            )
                        )
                    }
                    continuation.resume(returning: lines)
                } else if error != nil {
                    gate.hasResumed = true
                    continuation.resume(returning: [])
                }
            }
        }
    }

    private func requestWhisperTranscription(audioURL: URL) async throws -> String {
        let endpoint = baseURL.appendingPathComponent("audio/transcriptions")
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        let boundary = "Boundary-\(UUID().uuidString)"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        let audioData = try Data(contentsOf: audioURL)
        var body = Data()

        // 添加 model 参数
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"model\"\r\n\r\n".data(using: .utf8)!)
        body.append("whisper-1\r\n".data(using: .utf8)!)

        // 添加 response_format = srt
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"response_format\"\r\n\r\n".data(using: .utf8)!)
        body.append("srt\r\n".data(using: .utf8)!)

        // 添加 file 参数
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"audio.m4a\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: audio/m4a\r\n\r\n".data(using: .utf8)!)
        body.append(audioData)
        body.append("\r\n".data(using: .utf8)!)

        body.append("--\(boundary)--\r\n".data(using: .utf8)!)
        request.httpBody = body

        let session = createProxyAwareSession()
        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, (200...299).contains(httpResponse.statusCode) else {
            let errorMsg = String(data: data, encoding: .utf8) ?? "HTTP 响应错误"
            throw NSError(domain: "WhisperAPIError", code: -1, userInfo: [NSLocalizedDescriptionKey: errorMsg])
        }

        return String(data: data, encoding: .utf8) ?? ""
    }

    private func extractChatGPTAccountID(from jwt: String) -> String? {
        let segments = jwt.components(separatedBy: ".")
        guard segments.count > 1 else { return nil }
        var base64 = segments[1]
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while base64.count % 4 != 0 {
            base64.append("=")
        }
        guard let data = Data(base64Encoded: base64),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let authClaim = json["https://api.openai.com/auth"] as? [String: Any],
              let accountID = authClaim["chatgpt_account_id"] as? String else {
            return nil
        }
        return accountID
    }

    private func requestTranslation(lines: [SubtitleLine], targetLanguage: String) async throws -> [SubtitleLine] {
        let textsToTranslate = lines.map { $0.originalText }.joined(separator: "\n---\n")
        let prompt = """
        请将以下字幕文本逐句翻译成\(targetLanguage)，保持相同的行数和分隔符 '---'，只返回翻译结果，不要多余解释：
        \(textsToTranslate)
        """

        var translatedContent: String?

        // 1. 如果是 ChatGPT OAuth 订阅 Token (参考 pi-coding-agent 调用 chatgpt.com/backend-api/codex/responses)
        if !apiKey.hasPrefix("sk-"), let codexURL = URL(string: "https://chatgpt.com/backend-api/codex/responses") {
            var codexReq = URLRequest(url: codexURL)
            codexReq.httpMethod = "POST"
            codexReq.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            codexReq.setValue("application/json", forHTTPHeaderField: "Content-Type")
            codexReq.setValue("responses=experimental", forHTTPHeaderField: "OpenAI-Beta")
            if let accountID = extractChatGPTAccountID(from: apiKey) {
                codexReq.setValue(accountID, forHTTPHeaderField: "chatgpt-account-id")
            }

            let codexPayload: [String: Any] = [
                "model": "gpt-5.1-codex-mini",
                "instructions": "You are a professional movie subtitle translator.",
                "input": [
                    [
                        "role": "user",
                        "content": [
                            ["type": "input_text", "text": prompt]
                        ]
                    ]
                ],
                "store": false
            ]
            codexReq.httpBody = try? JSONSerialization.data(withJSONObject: codexPayload)

            let session = createProxyAwareSession()
            if let (data, response) = try? await session.data(for: codexReq),
               let httpResp = response as? HTTPURLResponse, (200...299).contains(httpResp.statusCode),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let output = json["output"] as? [[String: Any]] {
                for item in output {
                    if let contentArr = item["content"] as? [[String: Any]] {
                        for c in contentArr {
                            if let text = c["text"] as? String, !text.isEmpty {
                                translatedContent = text
                                break
                            }
                        }
                    }
                }
            }
        }

        // 2. 如果未通过 Codex OAuth 拿到翻译，走标准 OpenAI chat/completions
        if translatedContent == nil {
            let endpoint = baseURL.appendingPathComponent("chat/completions")
            var request = URLRequest(url: endpoint)
            request.httpMethod = "POST"
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")

            let payload: [String: Any] = [
                "model": "gpt-4o-mini",
                "messages": [
                    ["role": "system", "content": "You are a professional movie subtitle translator."],
                    ["role": "user", "content": prompt]
                ],
                "temperature": 0.3
            ]

            request.httpBody = try? JSONSerialization.data(withJSONObject: payload)

            let session = createProxyAwareSession()
            if let (data, response) = try? await session.data(for: request),
               let httpResponse = response as? HTTPURLResponse, (200...299).contains(httpResponse.statusCode),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let choices = json["choices"] as? [[String: Any]],
               let firstChoice = choices.first,
               let message = firstChoice["message"] as? [String: Any],
               let content = message["content"] as? String {
                translatedContent = content
            }
        }

        guard let content = translatedContent else {
            return lines
        }

        let translatedParts = content.components(separatedBy: "---").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        var result: [SubtitleLine] = []
        for (i, line) in lines.enumerated() {
            let trans = i < translatedParts.count ? translatedParts[i] : line.originalText
            result.append(
                SubtitleLine(
                    id: line.id,
                    startTime: line.startTime,
                    endTime: line.endTime,
                    originalText: line.originalText,
                    translatedText: trans
                )
            )
        }
        return result
    }
}
