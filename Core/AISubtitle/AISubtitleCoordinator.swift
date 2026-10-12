import Foundation

public enum AISubtitleEngineType: String, Codable, Sendable {
    case localWhisperKit
    case cloudOpenAI
    case cloudAntigravity
}

public protocol AISubtitleServiceProtocol: Sendable {
    func transcribeAndTranslate(audioURL: URL, targetLanguage: String) async throws -> [SubtitleLine]
}

public final class AISubtitleCoordinator: @unchecked Sendable {
    public static let shared = AISubtitleCoordinator()

    public var isEnabled: Bool = false
    public var currentEngine: AISubtitleEngineType = .localWhisperKit

    private init() {}

    /// 提取视频音轨转换为兼容的 m4a/wav 音频
    public func extractAudioTrack(from videoURL: URL, outputAudioURL: URL) async throws {
        // 音频抽取逻辑
    }

    /// 触发识别并翻译流程
    public func processVideo(
        videoURL: URL,
        targetLanguage: String = "zh"
    ) async throws -> [SubtitleLine] {
        guard isEnabled else {
            return []
        }
        
        // 1. 抽取音频
        // 2. 调度 Whisper 识别 (识别原语言与时间戳)
        // 3. 调度翻译模型 (例如将英语/日语翻译为中文)
        // 4. 返回带双语对照的字幕流
        return []
    }
}
