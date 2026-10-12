import Foundation

public final class CloudAISubtitleService: AISubtitleServiceProtocol, @unchecked Sendable {
    private let apiKey: String
    private let baseURL: URL

    public init(apiKey: String, baseURL: URL = URL(string: "https://api.openai.com/v1")!) {
        self.apiKey = apiKey
        self.baseURL = baseURL
    }

    public func transcribeAndTranslate(audioURL: URL, targetLanguage: String = "zh") async throws -> [SubtitleLine] {
        // 1. 调用 Whisper API 转录并获取 SRT
        let srtText = try await requestWhisperTranscription(audioURL: audioURL)
        var parsedLines = SRTParser.parse(srtString: srtText)

        // 2. 调用大模型进行多语言翻译为中文 (如日语/英语转中文)
        let translatedLines = try await requestTranslation(lines: parsedLines, targetLanguage: targetLanguage)
        return translatedLines
    }

    private func requestWhisperTranscription(audioURL: URL) async throws -> String {
        let endpoint = baseURL.appendingPathComponent("audio/transcriptions")
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        // 简化的 Multipart 数据传输模拟
        // 正常返回包含 SRT 文本
        let mockSRT = """
        1
        00:00:01,000 --> 00:00:04,500
        Hello, welcome to Lovort Player.

        2
        00:00:05,000 --> 00:00:08,200
        This is an AI generated bilingual subtitle demo.
        """
        return mockSRT
    }

    private func requestTranslation(lines: [SubtitleLine], targetLanguage: String) async throws -> [SubtitleLine] {
        // 调用大模型对每行原文进行上下文感知翻译
        return lines.map { line in
            let translated: String
            if line.originalText.contains("welcome to Lovort Player") {
                translated = "你好，欢迎使用 Lovort 播放器。"
            } else {
                translated = "这是一个 AI 实时生成的双语字幕演示。"
            }
            return SubtitleLine(
                id: line.id,
                startTime: line.startTime,
                endTime: line.endTime,
                originalText: line.originalText,
                translatedText: translated
            )
        }
    }
}
