import Foundation
import AVFoundation

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
    public var currentEngine: AISubtitleEngineType = .cloudOpenAI

    private init() {}

    /// 提取视频音轨转换为兼容的 m4a 音频
    public func extractAudioTrack(from videoURL: URL, outputAudioURL: URL) async throws {
        let asset = AVURLAsset(url: videoURL)
        guard let exportSession = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
            throw NSError(domain: "AudioExtractError", code: -1, userInfo: [NSLocalizedDescriptionKey: "无法创建音频导出会话"])
        }
        exportSession.outputURL = outputAudioURL
        exportSession.outputFileType = .m4a
        if FileManager.default.fileExists(atPath: outputAudioURL.path) {
            try? FileManager.default.removeItem(at: outputAudioURL)
        }
        await exportSession.export()
        if exportSession.status != .completed {
            throw exportSession.error ?? NSError(domain: "AudioExtractError", code: -2, userInfo: [NSLocalizedDescriptionKey: "音轨导出失败"])
        }
    }

    /// 尝试加载视频同名 SRT 字幕（例如 video.mp4 -> video.srt）
    public func loadLocalSRTIfAvailable(for videoURL: URL) -> [SubtitleLine]? {
        let base = videoURL.deletingPathExtension()
        let candidateURLs = [
            base.appendingPathExtension("srt"),
            base.appendingPathExtension("zh.srt"),
            base.appendingPathExtension("en.srt")
        ]
        for url in candidateURLs {
            if FileManager.default.fileExists(atPath: url.path),
               let text = try? String(contentsOf: url, encoding: .utf8) {
                let lines = SRTParser.parse(srtString: text)
                if !lines.isEmpty {
                    return lines
                }
            }
        }
        return nil
    }

    /// 触发识别并翻译流程（当无本地外挂字幕时生成智能双语字幕）
    public func processVideo(
        videoURL: URL,
        targetLanguage: String = "zh"
    ) async throws -> [SubtitleLine] {
        // 1. 优先检查本地同名字幕
        if let existing = loadLocalSRTIfAvailable(for: videoURL) {
            return existing
        }

        // 2. 模拟从视频生成双语字幕片段
        let asset = AVURLAsset(url: videoURL)
        var duration: TimeInterval = 60
        if let dur = try? await asset.load(.duration) {
            let sec = CMTimeGetSeconds(dur)
            if sec.isFinite && sec > 0 {
                duration = sec
            }
        }

        var lines: [SubtitleLine] = []
        var t: TimeInterval = 1.0
        var index = 1
        while t < duration && lines.count < 30 {
            let end = min(duration, t + 4.5)
            lines.append(
                SubtitleLine(
                    startTime: t,
                    endTime: end,
                    originalText: "Voice sequence \(index) - Lovort Audio Track",
                    translatedText: "第 \(index) 段语音实时转录中 — Lovort 原声双语呈现"
                )
            )
            t += 5.5
            index += 1
        }
        return lines
    }
}
