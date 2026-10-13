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

    public func transcribeAndTranslate(audioURL: URL, targetLanguage: String) async throws -> [SubtitleLine] {
        try await transcribeAndTranslate(audioURL: audioURL, targetLanguage: targetLanguage, sourceLanguage: "自动检测", onProgress: nil)
    }

    public func transcribeAndTranslate(
        audioURL: URL,
        targetLanguage: String = "zh",
        sourceLanguage: String = "自动检测",
        onProgress: (@Sendable (String) -> Void)? = nil
    ) async throws -> [SubtitleLine] {
        var parsedLines: [SubtitleLine] = []

        // 1. 如果是 sk- 开头的 OpenAI Platform Key，优先尝试 Whisper API
        if apiKey.hasPrefix("sk-") {
            onProgress?("正在调用 Whisper API 进行语音转录...")
            if let srtText = try? await requestWhisperTranscription(audioURL: audioURL) {
                parsedLines = SRTParser.parse(srtString: srtText)
            }
        }

        // 2. 若未走 Whisper 或 Whisper 失败，使用高精度分片语音识别（突破 1 分钟限制，支持任意长视频）
        if parsedLines.isEmpty {
            onProgress?("正在使用原生语音引擎分片识别长音轨...")
            parsedLines = await transcribeWithAppleSpeechChunked(audioURL: audioURL, sourceLanguage: sourceLanguage, onProgress: onProgress)
        }

        guard !parsedLines.isEmpty else {
            throw NSError(domain: "AISubtitleError", code: -10, userInfo: [NSLocalizedDescriptionKey: "未能从音轨中检测到清晰语音台词，请确认视频包含人声"])
        }

        // 3. 将转录文字传给 GPT (支持 ChatGPT Plus/Pro OAuth 订阅通道与 API Key 通道) 做上下文双语翻译润色
        onProgress?("正在调用 GPT 订阅大模型进行双语润色与对齐 (共 \(parsedLines.count) 句)...")
        let translatedLines = try await requestTranslation(lines: parsedLines, targetLanguage: targetLanguage)
        return translatedLines
    }

    /// 长音频分片转录（按 35 秒为一段依次切割音频，绕过 iOS 系统的 1 分钟限制，支持几小时长视频）
    private func transcribeWithAppleSpeechChunked(
        audioURL: URL,
        sourceLanguage: String,
        onProgress: (@Sendable (String) -> Void)?
    ) async -> [SubtitleLine] {
        let authorized = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status == .authorized)
            }
        }
        guard authorized else { return [] }

        let asset = AVURLAsset(url: audioURL)
        var totalDuration: TimeInterval = 0
        if let dur = try? await asset.load(.duration) {
            let sec = CMTimeGetSeconds(dur)
            if sec.isFinite && sec > 0 {
                totalDuration = sec
            }
        }

        guard totalDuration > 0 else { return [] }

        // 选择最佳语言 Locale
        var locale = Locale(identifier: "zh-CN")
        if sourceLanguage.contains("英") || sourceLanguage.lowercased().contains("en") {
            locale = Locale(identifier: "en-US")
        } else if sourceLanguage.contains("日") || sourceLanguage.lowercased().contains("ja") {
            locale = Locale(identifier: "ja-JP")
        } else if let sysLocale = SFSpeechRecognizer.supportedLocales().first(where: { $0.identifier == Locale.current.identifier }) {
            locale = sysLocale
        }

        let recognizer = SFSpeechRecognizer(locale: locale) ?? SFSpeechRecognizer()
        guard let recognizer = recognizer, recognizer.isAvailable else { return [] }

        // 如果时长小于 45 秒，直接单次识别
        if totalDuration <= 45.0 {
            return await recognizeSingleAudioClip(audioURL: audioURL, recognizer: recognizer, timeOffset: 0)
        }

        // 长音频按 35 秒切片依次识别
        let sliceDuration: TimeInterval = 35.0
        var currentStart: TimeInterval = 0
        var allLines: [SubtitleLine] = []
        let totalSlices = Int(ceil(totalDuration / sliceDuration))
        var sliceIndex = 1

        while currentStart < totalDuration {
            let thisDuration = min(sliceDuration, totalDuration - currentStart)
            onProgress?("正在语音识别分片 (\(sliceIndex)/\(totalSlices))...")

            let sliceURL = FileManager.default.temporaryDirectory.appendingPathComponent("slice_\(UUID().uuidString).m4a")
            let exportSuccess = await exportAudioSlice(
                asset: asset,
                from: currentStart,
                duration: thisDuration,
                outputURL: sliceURL
            )

            if exportSuccess {
                let sliceLines = await recognizeSingleAudioClip(
                    audioURL: sliceURL,
                    recognizer: recognizer,
                    timeOffset: currentStart
                )
                allLines.append(contentsOf: sliceLines)
                try? FileManager.default.removeItem(at: sliceURL)
            }

            currentStart += thisDuration
            sliceIndex += 1
        }

        return allLines
    }

    /// 截取音频的一个短分片
    private func exportAudioSlice(asset: AVURLAsset, from startSec: TimeInterval, duration durSec: TimeInterval, outputURL: URL) async -> Bool {
        guard let exportSession = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
            return false
        }
        exportSession.outputURL = outputURL
        exportSession.outputFileType = .m4a
        exportSession.timeRange = CMTimeRange(
            start: CMTime(seconds: startSec, preferredTimescale: 600),
            duration: CMTime(seconds: durSec, preferredTimescale: 600)
        )
        if FileManager.default.fileExists(atPath: outputURL.path) {
            try? FileManager.default.removeItem(at: outputURL)
        }
        await exportSession.export()
        return exportSession.status == .completed
    }

    /// 识别单个短音频片段并映射全局时间戳
    private func recognizeSingleAudioClip(
        audioURL: URL,
        recognizer: SFSpeechRecognizer,
        timeOffset: TimeInterval
    ) async -> [SubtitleLine] {
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
                            chunkStart = timeOffset + segment.timestamp
                        }
                        currentText += (currentText.isEmpty ? "" : " ") + segment.substring
                        lastEnd = timeOffset + segment.timestamp + segment.duration

                        if currentText.count >= 32 || segment.substring.hasSuffix(".") || segment.substring.hasSuffix("?") || segment.substring.hasSuffix("!") || segment.substring.hasSuffix("。") || segment.substring.hasSuffix("？") || (lastEnd - chunkStart) >= 4.0 {
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
                                endTime: max(chunkStart + 1.2, lastEnd),
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

        let activeModel = await MainActor.run {
            AIModelManager.shared.selectedModelID
        }

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
                "model": activeModel,
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
                "model": activeModel,
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
