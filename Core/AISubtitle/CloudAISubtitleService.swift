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

        // 选择最佳语言 Locale (优先支持动漫日语、欧美影视英语、华语与韩语)
        var locale = Locale(identifier: "ja-JP") // 动漫影视优先默认日语
        let lowerLang = sourceLanguage.lowercased()
        if lowerLang.contains("日") || lowerLang.contains("ja") || lowerLang.contains("jp") || lowerLang.contains("动漫") || lowerLang.contains("anime") {
            locale = Locale(identifier: "ja-JP")
        } else if lowerLang.contains("英") || lowerLang.contains("en") {
            locale = Locale(identifier: "en-US")
        } else if lowerLang.contains("中") || lowerLang.contains("zh") || lowerLang.contains("国语") || lowerLang.contains("普通话") {
            locale = Locale(identifier: "zh-CN")
        } else if lowerLang.contains("韩") || lowerLang.contains("ko") {
            locale = Locale(identifier: "ko-KR")
        } else {
            // "自动检测"：检查文件名或当前环境
            let filename = audioURL.lastPathComponent.lowercased()
            if filename.contains("anime") || filename.contains("raw") || filename.contains("ep") || filename.contains("sub") || filename.contains("ova") || filename.contains("movie") || filename.contains("bebop") || filename.contains("jin") {
                locale = Locale(identifier: "ja-JP")
            } else if let sysLocale = SFSpeechRecognizer.supportedLocales().first(where: { $0.identifier == Locale.current.identifier }) {
                locale = sysLocale
            } else {
                locale = Locale(identifier: "ja-JP")
            }
        }

        let recognizer = SFSpeechRecognizer(locale: locale) ?? SFSpeechRecognizer(locale: Locale(identifier: "ja-JP")) ?? SFSpeechRecognizer()
        guard let recognizer = recognizer, recognizer.isAvailable else { return [] }

        // 如果时长小于 45 秒，直接单次识别
        if totalDuration <= 45.0 {
            return await recognizeSingleAudioClip(audioURL: audioURL, recognizer: recognizer, locale: locale, timeOffset: 0)
        }

        // 长音频采用 32 秒切片，步长 28 秒（4秒滑动交叠，防止任何台词被截断在切片边界）
        let sliceDuration: TimeInterval = 32.0
        let stepDuration: TimeInterval = 28.0
        var currentStart: TimeInterval = 0
        var allLines: [SubtitleLine] = []
        let totalSlices = Int(ceil(totalDuration / stepDuration))
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
                    locale: locale,
                    timeOffset: currentStart
                )
                // 智能合并交叠段，去重相邻时间戳相同的台词
                allLines = mergeSubtitleLines(existing: allLines, incoming: sliceLines)
                try? FileManager.default.removeItem(at: sliceURL)
            }

            currentStart += stepDuration
            sliceIndex += 1
        }

        return allLines
    }

    /// 智能合并重叠分片的台词，避免重复
    private func mergeSubtitleLines(existing: [SubtitleLine], incoming: [SubtitleLine]) -> [SubtitleLine] {
        var merged = existing
        for line in incoming {
            if let last = merged.last {
                // 如果与上一句时间差小于 2 秒，且文本高度重叠或完全一致，去重
                if abs(last.startTime - line.startTime) < 2.0 {
                    if last.originalText == line.originalText || last.originalText.contains(line.originalText) {
                        continue
                    }
                    if line.originalText.contains(last.originalText) {
                        merged.removeLast()
                        merged.append(line)
                        continue
                    }
                }
            }
            merged.append(line)
        }
        return merged
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

    /// 识别单个短音频片段并映射全局时间戳（持续保存 latestTranscription，EOF 不丢弃非 final 结果）
    private func recognizeSingleAudioClip(
        audioURL: URL,
        recognizer: SFSpeechRecognizer,
        locale: Locale,
        timeOffset: TimeInterval
    ) async -> [SubtitleLine] {
        let request = SFSpeechURLRecognitionRequest(url: audioURL)
        request.shouldReportPartialResults = false

        final class RecognitionHolder: @unchecked Sendable {
            var hasResumed = false
            var bestTranscription: SFTranscription?
        }
        let holder = RecognitionHolder()

        return await withCheckedContinuation { continuation in
            recognizer.recognitionTask(with: request) { result, error in
                guard !holder.hasResumed else { return }
                if let r = result {
                    holder.bestTranscription = r.bestTranscription
                }

                if result?.isFinal == true || error != nil {
                    holder.hasResumed = true
                    guard let transcription = holder.bestTranscription else {
                        continuation.resume(returning: [])
                        return
                    }

                    var lines: [SubtitleLine] = []
                    var currentText = ""
                    var chunkStart: TimeInterval = 0
                    var lastEnd: TimeInterval = 0

                    let isCJK = locale.identifier.hasPrefix("ja") || locale.identifier.hasPrefix("zh")

                    for segment in transcription.segments {
                        if currentText.isEmpty {
                            chunkStart = timeOffset + segment.timestamp
                        }
                        let separator = (currentText.isEmpty || isCJK) ? "" : " "
                        currentText += separator + segment.substring
                        lastEnd = timeOffset + segment.timestamp + segment.duration

                        let sub = segment.substring
                        let isPunctuationEnd = sub.hasSuffix(".") || sub.hasSuffix("?") || sub.hasSuffix("!") || sub.hasSuffix("。") || sub.hasSuffix("？") || sub.hasSuffix("！") || sub.hasSuffix("…") || sub.hasSuffix("、")

                        if currentText.count >= (isCJK ? 24 : 36) || isPunctuationEnd || (lastEnd - chunkStart) >= 4.5 {
                            lines.append(
                                SubtitleLine(
                                    startTime: chunkStart,
                                    endTime: max(chunkStart + 1.2, lastEnd),
                                    originalText: currentText.trimmingCharacters(in: .whitespacesAndNewlines),
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
                                originalText: currentText.trimmingCharacters(in: .whitespacesAndNewlines),
                                translatedText: ""
                            )
                        )
                    }
                    continuation.resume(returning: lines)
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
        你是一位顶级专业动漫字幕组与影视本地化翻译专家。
        请将以下原始台词逐句翻译为\(targetLanguage)，保持原汁原味的语境、角色性格与文化内涵（保留合适的动漫称呼与语气习惯，避免机械直译）。
        严格保持相同的行数与 '---' 分隔符，只输出对应翻译文本：
        \(textsToTranslate)
        """

        var translatedContent: String?

        let activeModel = await MainActor.run {
            AIModelManager.shared.selectedModelID
        }

        let fallbackCandidateModels = [activeModel, "gpt-6.1-sol", "gpt-6-sol", "gpt-6-astra", "gpt-5.6-sol", "gpt-4o-mini"]

        // 1. 如果是 ChatGPT OAuth 订阅 Token (调用 chatgpt.com/backend-api/codex/responses)
        if !apiKey.hasPrefix("sk-"), let codexURL = URL(string: "https://chatgpt.com/backend-api/codex/responses") {
            let session = createProxyAwareSession()
            let accountID = extractChatGPTAccountID(from: apiKey)

            for tryModel in fallbackCandidateModels {
                var codexReq = URLRequest(url: codexURL)
                codexReq.httpMethod = "POST"
                codexReq.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
                codexReq.setValue("application/json", forHTTPHeaderField: "Content-Type")
                codexReq.setValue("responses=experimental", forHTTPHeaderField: "OpenAI-Beta")
                if let accountID = accountID {
                    codexReq.setValue(accountID, forHTTPHeaderField: "chatgpt-account-id")
                }

                let codexPayload: [String: Any] = [
                    "model": tryModel,
                    "instructions": "You are a professional anime and movie fansub translator. Translate dialogue into authentic natural subtitles.",
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
                    if translatedContent != nil {
                        break
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
