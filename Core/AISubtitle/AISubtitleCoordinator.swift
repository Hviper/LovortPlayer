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

    private let openAIKeyStorageKey = "LovortOpenAIAPIKey"

    private init() {}

    public func getSavedOpenAIKey() -> String {
        UserDefaults.standard.string(forKey: openAIKeyStorageKey) ?? ""
    }

    public func saveOpenAIKey(_ key: String) {
        UserDefaults.standard.set(key, forKey: openAIKeyStorageKey)
    }

    /// 提取视频音轨转换为兼容的 m4a 音频（针对多音轨视频智能匹配日语动漫音轨或主音轨）
    public func extractAudioTrack(from videoURL: URL, outputAudioURL: URL) async throws {
        let asset = AVURLAsset(url: videoURL)
        let audioTracks = try? await asset.loadTracks(withMediaType: .audio)

        var targetTrack: AVAssetTrack? = nil
        if let tracks = audioTracks, !tracks.isEmpty {
            for track in tracks {
                let lang = (track.extendedLanguageTag ?? track.languageCode ?? "").lowercased()
                if lang.contains("ja") || lang.contains("jpn") {
                    targetTrack = track
                    break
                }
            }
            if targetTrack == nil {
                targetTrack = tracks.first
            }
        }

        var sourceAsset: AVAsset = asset
        if let selectedTrack = targetTrack, let tracks = audioTracks, tracks.count > 1 {
            let composition = AVMutableComposition()
            if let compAudioTrack = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid),
               let timeRange = try? await selectedTrack.load(.timeRange) {
                try? compAudioTrack.insertTimeRange(timeRange, of: selectedTrack, at: .zero)
                sourceAsset = composition
            }
        }

        guard let exportSession = AVAssetExportSession(asset: sourceAsset, presetName: AVAssetExportPresetAppleM4A) else {
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
            base.appendingPathExtension("ja.srt"),
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

    /// 触发识别并翻译流程，完成之后自动将双语字幕持久化保存为该视频的本地离线 .srt 文件
    public func processVideo(
        videoURL: URL,
        targetLanguage: String = "zh",
        sourceLanguage: String = "自动检测",
        onProgress: (@Sendable (String) -> Void)? = nil
    ) async throws -> [SubtitleLine] {
        // 1. 优先检查本地是否已有同名 SRT（若有直接秒级装载离线字幕）
        if let existing = loadLocalSRTIfAvailable(for: videoURL) {
            onProgress?("已加载本地离线字幕 (共 \(existing.count) 句)")
            return existing
        }

        // 2. 社区字幕库智能检索（开源射手网 / 动漫字幕组精校库秒级匹配）
        onProgress?("正在社区字幕组库检索该视频是否有精校字幕...")
        if let communitySubs = try? await ShooterSubtitleService.shared.fetchCommunitySubtitles(videoURL: videoURL),
           let bestSub = communitySubs.first {
            onProgress?("找到社区精校字幕：\(bestSub.desc)，正在秒级同步...")
            if let lines = try? await ShooterSubtitleService.shared.downloadAndParseSubtitle(from: bestSub.downloadURL), !lines.isEmpty {
                let targetSRTURL = videoURL.deletingPathExtension().appendingPathExtension("srt")
                let srtContent = SRTParser.generateSRT(from: lines)
                try? srtContent.write(to: targetSRTURL, atomically: true, encoding: .utf8)
                onProgress?("✅ 已成功匹配社区字幕组精校字幕 (共 \(lines.count) 句)")
                return lines
            }
        }

        // 2. 读取认证 Key（优先读取手动填写的 OpenAI Key，若无则读取已登录的 ChatGPT Plus/Pro 订阅 Token）
        var activeToken = getSavedOpenAIKey().trimmingCharacters(in: .whitespacesAndNewlines)
        if activeToken.isEmpty {
            activeToken = await MainActor.run {
                AuthManager.shared.currentProfile?.accessToken ?? ""
            }.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        // 3. 提取视频音轨
        onProgress?("正在提取无损视频音轨...")
        let tempAudioURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".m4a")
        defer {
            try? FileManager.default.removeItem(at: tempAudioURL)
        }
        try await extractAudioTrack(from: videoURL, outputAudioURL: tempAudioURL)

        // 4. 调用智能分片转录与大模型双语翻译
        let cloudService = CloudAISubtitleService(apiKey: activeToken)
        let lines = try await cloudService.transcribeAndTranslate(
            audioURL: tempAudioURL,
            targetLanguage: targetLanguage,
            sourceLanguage: sourceLanguage,
            onProgress: onProgress
        )

        guard !lines.isEmpty else {
            throw NSError(
                domain: "AISubtitleError",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "未检测到有效台词或大模型未返回结果，请确认视频包含清晰人声或检查网络代理"]
            )
        }

        // 5. 自动持久化落盘为视频同级 .srt 离线字幕文件（这样观影时无需联网即开即显！）
        let srtContent = SRTParser.generateSRT(from: lines)
        let targetSRTURL = videoURL.deletingPathExtension().appendingPathExtension("srt")
        do {
            try srtContent.write(to: targetSRTURL, atomically: true, encoding: .utf8)
            onProgress?("✅ 已生成并保存离线字幕 (共 \(lines.count) 句)")
        } catch {
            // 若原目录受沙盒只读限制，保存到 Documents 目录
            let docsDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            let fallbackSRTURL = docsDir.appendingPathComponent(videoURL.deletingPathExtension().lastPathComponent).appendingPathExtension("srt")
            try? srtContent.write(to: fallbackSRTURL, atomically: true, encoding: .utf8)
            onProgress?("✅ 已保存离线字幕到本地 (共 \(lines.count) 句)")
        }

        return lines
    }
}
