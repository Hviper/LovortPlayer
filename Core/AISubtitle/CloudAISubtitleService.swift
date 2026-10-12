import Foundation

public final class CloudAISubtitleService: AISubtitleServiceProtocol, @unchecked Sendable {
    private let apiKey: String
    private let baseURL: URL

    public init(apiKey: String, baseURL: URL = URL(string: "https://api.openai.com/v1")!) {
        self.apiKey = apiKey
        self.baseURL = baseURL
    }

    public func transcribeAndTranslate(audioURL: URL, targetLanguage: String = "zh") async throws -> [SubtitleLine] {
        // 1. 调用真实 Whisper API 转录获取 SRT 文本
        let srtText = try await requestWhisperTranscription(audioURL: audioURL)
        let parsedLines = SRTParser.parse(srtString: srtText)

        if parsedLines.isEmpty {
            return []
        }

        // 2. 将转录文字传给 GPT 做上下文翻译
        let translatedLines = try await requestTranslation(lines: parsedLines, targetLanguage: targetLanguage)
        return translatedLines
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

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, (200...299).contains(httpResponse.statusCode) else {
            let errorMsg = String(data: data, encoding: .utf8) ?? "HTTP Error"
            throw NSError(domain: "WhisperAPIError", code: -1, userInfo: [NSLocalizedDescriptionKey: errorMsg])
        }

        return String(data: data, encoding: .utf8) ?? ""
    }

    private func requestTranslation(lines: [SubtitleLine], targetLanguage: String) async throws -> [SubtitleLine] {
        // 构建简单的翻译 Prompt 发送到 chat/completions
        let endpoint = baseURL.appendingPathComponent("chat/completions")
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let textsToTranslate = lines.map { $0.originalText }.joined(separator: "\n---\n")
        let prompt = """
        请将以下字幕文本逐句翻译成\(targetLanguage)，保持相同的行数和分隔符 '---'，只返回翻译结果，不要多余解释：
        \(textsToTranslate)
        """

        let payload: [String: Any] = [
            "model": "gpt-4o-mini",
            "messages": [
                ["role": "system", "content": "You are a professional movie subtitle translator."],
                ["role": "user", "content": prompt]
            ],
            "temperature": 0.3
        ]

        request.httpBody = try? JSONSerialization.data(withJSONObject: payload)

        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let httpResponse = response as? HTTPURLResponse, (200...299).contains(httpResponse.statusCode),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let firstChoice = choices.first,
              let message = firstChoice["message"] as? [String: Any],
              let content = message["content"] as? String else {
            // 如果翻译失败，退回原文
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
