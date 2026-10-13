import AVFoundation
import Foundation

public final class CloudAISubtitleService: @unchecked Sendable {
    private let apiKey: String
    private let baseURL: URL
    private let maximumUploadBytes = 24 * 1_024 * 1_024
    private let cloudSliceDuration: TimeInterval = 4 * 60

    public init(apiKey: String, baseURL: URL = URL(string: "https://api.openai.com/v1")!) {
        self.apiKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        self.baseURL = baseURL
    }

    public func transcribe(
        audioURL: URL,
        sourceLanguage: SubtitleSourceLanguage,
        onProgress: (@Sendable (String) -> Void)? = nil
    ) async throws -> [SubtitleLine] {
        guard apiKey.hasPrefix("sk-") else {
            throw serviceError("云端语音转写需要 OpenAI Platform API Key；ChatGPT 订阅令牌不能调用音频接口")
        }

        let asset = AVURLAsset(url: audioURL)
        let durationValue = try await asset.load(.duration)
        let duration = CMTimeGetSeconds(durationValue)
        guard duration.isFinite, duration > 0 else { throw serviceError("无法读取待转写音频的时长") }

        let fileSize = (try? audioURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        if fileSize > 0, fileSize <= maximumUploadBytes {
            onProgress?("正在使用 OpenAI Whisper 转写音频...")
            return try await requestWhisperTranscription(
                audioURL: audioURL,
                language: sourceLanguage.whisperCode
            )
        }

        var allLines: [SubtitleLine] = []
        let totalSlices = Int(ceil(duration / cloudSliceDuration))
        for index in 0..<totalSlices {
            try Task.checkCancellation()
            let start = TimeInterval(index) * cloudSliceDuration
            let sliceDuration = min(cloudSliceDuration, duration - start)
            let sliceURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("lovort-cloud-\(UUID().uuidString).m4a")
            defer { try? FileManager.default.removeItem(at: sliceURL) }

            onProgress?("正在处理云端转写分片 \(index + 1)/\(totalSlices)...")
            try await exportAudioSlice(asset: asset, start: start, duration: sliceDuration, outputURL: sliceURL)
            let sliceLines = try await requestWhisperTranscription(
                audioURL: sliceURL,
                language: sourceLanguage.whisperCode
            )
            allLines.append(contentsOf: sliceLines.map { line in
                SubtitleLine(
                    id: line.id,
                    startTime: line.startTime + start,
                    endTime: line.endTime + start,
                    originalText: line.originalText,
                    translatedText: line.translatedText
                )
            })
        }
        return allLines
    }

    public func translate(
        lines: [SubtitleLine],
        targetLanguage: String,
        onProgress: (@Sendable (String) -> Void)? = nil
    ) async throws -> [SubtitleLine] {
        guard !lines.isEmpty else { return [] }
        guard !apiKey.isEmpty else { return lines }

        let batches = makeTranslationBatches(lines)
        var translatedByID: [UUID: String] = [:]
        for (batchIndex, batch) in batches.enumerated() {
            try Task.checkCancellation()
            onProgress?("正在翻译字幕 \(batchIndex + 1)/\(batches.count)...")
            let values = try await requestTranslationBatch(lines: batch, targetLanguage: targetLanguage)
            for (index, line) in batch.enumerated() where index < values.count {
                let value = values[index].trimmingCharacters(in: .whitespacesAndNewlines)
                if !value.isEmpty { translatedByID[line.id] = value }
            }
        }

        guard translatedByID.count == lines.count else {
            throw serviceError("翻译结果数量不完整（收到 \(translatedByID.count)/\(lines.count) 句），已保留原文字幕")
        }
        return lines.map { line in
            SubtitleLine(
                id: line.id,
                startTime: line.startTime,
                endTime: line.endTime,
                originalText: line.originalText,
                translatedText: translatedByID[line.id]
            )
        }
    }

    public func polish(
        lines: [SubtitleLine],
        targetLanguage: String,
        onProgress: (@Sendable (String) -> Void)? = nil
    ) async throws -> [SubtitleLine] {
        guard apiKey.hasPrefix("sk-") else { throw serviceError("GPT 语境精修需要 OpenAI Platform API Key") }
        guard lines.allSatisfy({ !($0.translatedText ?? "").isEmpty }) else {
            throw serviceError("GPT 语境精修需要先生成完整译文")
        }
        let batches = makeTranslationBatches(lines)
        var polishedByID: [UUID: String] = [:]
        for (batchIndex, batch) in batches.enumerated() {
            try Task.checkCancellation()
            onProgress?("正在使用 GPT 统一人物称谓与影视语气 \(batchIndex + 1)/\(batches.count)...")
            let values = try await requestPolishBatch(lines: batch, targetLanguage: targetLanguage)
            guard values.count == batch.count else { throw serviceError("GPT 精修结果数量不完整") }
            for (index, line) in batch.enumerated() { polishedByID[line.id] = values[index] }
        }
        return lines.map { line in
            SubtitleLine(
                id: line.id,
                startTime: line.startTime,
                endTime: line.endTime,
                originalText: line.originalText,
                translatedText: polishedByID[line.id] ?? line.translatedText
            )
        }
    }

    private func makeTranslationBatches(_ lines: [SubtitleLine]) -> [[SubtitleLine]] {
        var result: [[SubtitleLine]] = []
        var current: [SubtitleLine] = []
        var characterCount = 0
        for line in lines {
            let nextCount = characterCount + line.originalText.count
            if !current.isEmpty, current.count >= 36 || nextCount > 7_000 {
                result.append(current)
                current = []
                characterCount = 0
            }
            current.append(line)
            characterCount += line.originalText.count
        }
        if !current.isEmpty { result.append(current) }
        return result
    }

    private func requestTranslationBatch(lines: [SubtitleLine], targetLanguage: String) async throws -> [String] {
        let sourceObjects = lines.enumerated().map { index, line in
            ["index": index, "text": line.originalText] as [String: Any]
        }
        let sourceData = try JSONSerialization.data(withJSONObject: sourceObjects)
        let sourceJSON = String(decoding: sourceData, as: UTF8.self)
        let prompt = """
        将下面的影视台词翻译为“\(targetLanguage)”。结合整批上下文处理人名、称谓、俚语和语气，适合日漫或美剧字幕；不得增删、合并或拆分条目。
        只返回严格 JSON 数组，不要 Markdown。每项格式为 {"index": 原索引, "translation": "译文"}，必须覆盖 0 到 \(lines.count - 1)。
        输入：\(sourceJSON)
        """

        let activeModel = await MainActor.run { AIModelManager.shared.selectedModelID }
        let candidateModels = uniqueModels([activeModel, "gpt-6.1-sol", "gpt-6-luna"])
        var lastError: Error?
        for model in candidateModels {
            do {
                let content = try await requestTranslationText(prompt: prompt, model: model)
                return try Self.decodeTranslations(from: content, expectedCount: lines.count)
            } catch {
                lastError = error
                let status = (error as NSError).code
                if status == 401 || status == 403 || status == 429 || status >= 500 { break }
            }
        }
        throw lastError ?? serviceError("字幕翻译请求失败")
    }

    private func requestPolishBatch(lines: [SubtitleLine], targetLanguage: String) async throws -> [String] {
        let sourceObjects = lines.enumerated().map { index, line in
            [
                "index": index,
                "original": line.originalText,
                "draft": line.translatedText ?? ""
            ] as [String: Any]
        }
        let sourceData = try JSONSerialization.data(withJSONObject: sourceObjects)
        let sourceJSON = String(decoding: sourceData, as: UTF8.self)
        let prompt = """
        你是影视字幕总监。结合整批上下文，把下列“\(targetLanguage)”初译统一人名、称谓、敬语、俚语和角色语气。
        保持简洁自然，适合屏幕阅读；不得改变事实，不得增删、合并或拆分条目。
        只返回严格 JSON 数组，每项格式为 {"index": 原索引, "translation": "精修译文"}，必须覆盖 0 到 \(lines.count - 1)。
        输入：\(sourceJSON)
        """
        let activeModel = await MainActor.run { AIModelManager.shared.selectedModelID }
        let candidateModels = uniqueModels([activeModel, "gpt-6.1-sol", "gpt-6-luna"])
        var lastError: Error?
        for model in candidateModels {
            do {
                let content = try await requestPlatformResponse(prompt: prompt, model: model)
                return try Self.decodeTranslations(from: content, expectedCount: lines.count)
            } catch {
                lastError = error
                let status = (error as NSError).code
                if status == 401 || status == 403 || status == 429 || status >= 500 { break }
            }
        }
        throw lastError ?? serviceError("GPT 字幕精修失败")
    }

    static func decodeTranslations(from content: String, expectedCount: Int) throws -> [String] {
        guard let start = content.firstIndex(of: "["),
              let end = content.lastIndex(of: "]"),
              start <= end else {
            throw NSError(domain: "SubtitleTranslationError", code: -20, userInfo: [NSLocalizedDescriptionKey: "大模型未返回 JSON 数组"])
        }
        let data = Data(content[start...end].utf8)
        guard let objects = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw NSError(domain: "SubtitleTranslationError", code: -21, userInfo: [NSLocalizedDescriptionKey: "无法解析大模型翻译结果"])
        }
        var indexed: [Int: String] = [:]
        for object in objects {
            let index: Int?
            if let intValue = object["index"] as? Int {
                index = intValue
            } else if let numberValue = object["index"] as? NSNumber {
                index = numberValue.intValue
            } else if let stringValue = object["index"] as? String {
                index = Int(stringValue)
            } else {
                index = nil
            }
            if let index, let translation = object["translation"] as? String { indexed[index] = translation }
        }
        guard indexed.count == expectedCount else {
            throw NSError(domain: "SubtitleTranslationError", code: -22, userInfo: [NSLocalizedDescriptionKey: "大模型返回的字幕条目数不匹配"])
        }
        return try (0..<expectedCount).map { index in
            guard let value = indexed[index] else {
                throw NSError(domain: "SubtitleTranslationError", code: -23, userInfo: [NSLocalizedDescriptionKey: "翻译结果缺少第 \(index) 条字幕"])
            }
            return value
        }
    }

    private func requestTranslationText(prompt: String, model: String) async throws -> String {
        guard apiKey.hasPrefix("sk-") else {
            throw serviceError("OpenAI 请求需要 Platform API Key；ChatGPT 订阅令牌不能用于公开 API")
        }
        return try await requestPlatformResponse(prompt: prompt, model: model)
    }

    private func requestPlatformResponse(prompt: String, model: String) async throws -> String {
        var request = URLRequest(url: baseURL.appendingPathComponent("responses"))
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": model,
            "instructions": "You are a professional audiovisual subtitle translator. Return only the requested JSON.",
            "input": prompt,
            "store": false
        ])
        let (data, response) = try await createProxyAwareSession().data(for: request)
        try validate(response: response, data: data)
        return try extractResponseText(from: data)
    }


    static func extractStreamingResponseText(from data: Data) throws -> String {
        let payload = String(decoding: data, as: UTF8.self)
        var output = ""
        var completed = false
        var failureMessage: String?
        for line in payload.components(separatedBy: .newlines) where line.hasPrefix("data:") {
            let value = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            guard value != "[DONE]", let eventData = value.data(using: .utf8),
                  let event = try? JSONSerialization.jsonObject(with: eventData) as? [String: Any],
                  let type = event["type"] as? String else { continue }
            switch type {
            case "response.output_text.delta":
                output += event["delta"] as? String ?? ""
            case "response.completed":
                completed = true
                if output.isEmpty,
                   let response = event["response"] as? [String: Any],
                   let responseData = try? JSONSerialization.data(withJSONObject: response),
                   let text = try? extractResponseTextFromJSON(data: responseData) {
                    output = text
                }
            case "response.failed", "response.incomplete":
                if let response = event["response"] as? [String: Any],
                   let error = response["error"] as? [String: Any] {
                    failureMessage = error["message"] as? String ?? error["code"] as? String
                }
            default:
                continue
            }
        }
        guard completed else {
            throw NSError(
                domain: "OpenAIStreamingError",
                code: -30,
                userInfo: [NSLocalizedDescriptionKey: failureMessage ?? "ChatGPT 流式响应未正常完成"]
            )
        }
        guard !output.isEmpty else {
            throw NSError(
                domain: "OpenAIStreamingError",
                code: -31,
                userInfo: [NSLocalizedDescriptionKey: "ChatGPT 完成响应但没有返回译文"]
            )
        }
        return output
    }

    private static func extractResponseTextFromJSON(data: Data) throws -> String {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let output = json["output"] as? [[String: Any]] else {
            throw NSError(domain: "OpenAIStreamingError", code: -32)
        }
        for item in output {
            guard let content = item["content"] as? [[String: Any]] else { continue }
            for part in content {
                if let text = part["text"] as? String, !text.isEmpty { return text }
            }
        }
        throw NSError(domain: "OpenAIStreamingError", code: -33)
    }

    private func requestWhisperTranscription(audioURL: URL, language: String?) async throws -> [SubtitleLine] {
        let audioData = try Data(contentsOf: audioURL)
        guard audioData.count <= maximumUploadBytes else {
            throw serviceError("音频分片仍超过 OpenAI 25 MB 限制，请改用离线 WhisperKit")
        }

        let boundary = "Boundary-\(UUID().uuidString)"
        var body = Data()
        body.appendFormField(name: "model", value: "whisper-1", boundary: boundary)
        body.appendFormField(name: "response_format", value: "srt", boundary: boundary)
        if let language { body.appendFormField(name: "language", value: language, boundary: boundary) }
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"audio.m4a\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: audio/m4a\r\n\r\n".data(using: .utf8)!)
        body.append(audioData)
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)

        var request = URLRequest(url: baseURL.appendingPathComponent("audio/transcriptions"))
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = body

        let (data, response) = try await createProxyAwareSession().data(for: request)
        try validate(response: response, data: data)
        let lines = SRTParser.parse(srtString: String(decoding: data, as: UTF8.self))
        guard !lines.isEmpty else { throw serviceError("OpenAI 未返回可用的带时间戳字幕") }
        return lines
    }

    private func exportAudioSlice(asset: AVAsset, start: TimeInterval, duration: TimeInterval, outputURL: URL) async throws {
        guard let exportSession = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
            throw serviceError("无法创建云端音频分片")
        }
        exportSession.outputURL = outputURL
        exportSession.outputFileType = .m4a
        exportSession.timeRange = CMTimeRange(
            start: CMTime(seconds: start, preferredTimescale: 600),
            duration: CMTime(seconds: duration, preferredTimescale: 600)
        )
        try? FileManager.default.removeItem(at: outputURL)
        await exportSession.export()
        guard exportSession.status == .completed else {
            throw exportSession.error ?? serviceError("云端音频分片导出失败")
        }
    }

    private func createProxyAwareSession() -> URLSession {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 90
        configuration.timeoutIntervalForResource = 600
        let proxyHost = UserDefaults.standard.string(forKey: "LovortCustomProxyHost") ?? ""
        let proxyPort = UserDefaults.standard.integer(forKey: "LovortCustomProxyPort")
        if !proxyHost.isEmpty, proxyPort > 0 {
            configuration.connectionProxyDictionary = [
                "HTTPEnable": 1,
                "HTTPProxy": proxyHost,
                "HTTPPort": proxyPort,
                "HTTPSEnable": 1,
                "HTTPSProxy": proxyHost,
                "HTTPSPort": proxyPort
            ]
        }
        return URLSession(configuration: configuration)
    }

    private func validate(response: URLResponse, data: Data) throws {
        guard let httpResponse = response as? HTTPURLResponse, (200...299).contains(httpResponse.statusCode) else {
            let message = Self.apiErrorMessage(from: data)
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw NSError(domain: "OpenAIServiceError", code: status, userInfo: [NSLocalizedDescriptionKey: "OpenAI 请求失败（HTTP \(status)）：\(message)"])
        }
    }

    private func extractResponseText(from data: Data) throws -> String {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw serviceError("无法解析大模型响应")
        }
        if let outputText = json["output_text"] as? String, !outputText.isEmpty { return outputText }
        if let output = json["output"] as? [[String: Any]] {
            for item in output {
                guard let content = item["content"] as? [[String: Any]] else { continue }
                for part in content {
                    if let text = part["text"] as? String, !text.isEmpty { return text }
                }
            }
        }
        throw serviceError("大模型响应中没有文本内容")
    }

    private static func apiErrorMessage(from data: Data) -> String {
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let error = json["error"] as? [String: Any],
           let message = error["message"] as? String { return message }
        return String(decoding: data.prefix(600), as: UTF8.self)
    }

    private func uniqueModels(_ models: [String]) -> [String] {
        var seen = Set<String>()
        return models.filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    private func serviceError(_ message: String) -> NSError {
        NSError(domain: "AISubtitleServiceError", code: -1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}

private extension Data {
    mutating func appendFormField(name: String, value: String, boundary: String) {
        append("--\(boundary)\r\n".data(using: .utf8)!)
        append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".data(using: .utf8)!)
        append("\(value)\r\n".data(using: .utf8)!)
    }
}
