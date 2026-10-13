import Foundation
import WhisperKit

public enum OfflineWhisperModel: String, CaseIterable, Codable, Identifiable, Sendable {
    case highAccuracy = "large-v3-v20240930_626MB"
    case balanced = "small"
    case compact = "base"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .highAccuracy: return "高精度 · Large V3 Turbo（约 626 MB）"
        case .balanced: return "均衡 · Small"
        case .compact: return "轻量 · Base"
        }
    }

    public var detail: String {
        switch self {
        case .highAccuracy: return "推荐日语动漫和影视，准确率最高，首次下载较大"
        case .balanced: return "速度、内存和准确率较均衡"
        case .compact: return "旧设备更稳，速度快，但生词和多人对白准确率较低"
        }
    }
}

public enum SubtitleSourceLanguage: String, CaseIterable, Codable, Identifiable, Sendable {
    case japanese
    case english
    case chinese
    case korean
    case automatic

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .japanese: return "日语 (日本語 - 动漫/日剧)"
        case .english: return "英语 (English - 欧美影视)"
        case .chinese: return "中文 (普通话/粤语)"
        case .korean: return "韩语 (한국어)"
        case .automatic: return "自动智能检测"
        }
    }

    public var whisperCode: String? {
        switch self {
        case .japanese: return "ja"
        case .english: return "en"
        case .chinese: return "zh"
        case .korean: return "ko"
        case .automatic: return nil
        }
    }

    public var trackLanguageCandidates: [String] {
        switch self {
        case .japanese: return ["ja", "jpn"]
        case .english: return ["en", "eng"]
        case .chinese: return ["zh", "zho", "chi", "yue"]
        case .korean: return ["ko", "kor"]
        case .automatic: return []
        }
    }
}

public actor LocalWhisperSubtitleService {
    private var pipeline: WhisperKit?
    private var loadedModel: OfflineWhisperModel?

    public init() {}

    public func transcribe(
        audioURL: URL,
        sourceLanguage: SubtitleSourceLanguage,
        model: OfflineWhisperModel,
        onProgress: (@Sendable (String) -> Void)? = nil
    ) async throws -> [SubtitleLine] {
        if pipeline == nil || loadedModel != model {
            onProgress?("正在准备离线模型（首次使用需联网下载 (model.displayName)）...")
            pipeline = try await WhisperKit(
                WhisperKitConfig(
                    model: model.rawValue,
                    verbose: false,
                    prewarm: true,
                    load: true,
                    download: true,
                    useBackgroundDownloadSession: true
                )
            )
            loadedModel = model
        }

        guard let pipeline else {
            throw NSError(
                domain: "LocalWhisperError",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "离线语音模型加载失败"]
            )
        }

        let languageCode = sourceLanguage.whisperCode
        let options = DecodingOptions(
            task: .transcribe,
            language: languageCode,
            detectLanguage: languageCode == nil,
            skipSpecialTokens: true,
            wordTimestamps: true,
            noSpeechThreshold: 0.6,
            concurrentWorkerCount: 2,
            chunkingStrategy: .vad
        )
        let inputOptions = AudioInputOptions(
            channelMode: .sumChannels(nil),
            audioLoadingMode: .incremental
        )

        onProgress?("正在设备端离线识别语音（可保持此页面在前台）...")
        let results = await pipeline.transcribeWithResults(
            audioPaths: [audioURL.path],
            audioInputOptions: inputOptions,
            decodeOptions: options,
            callback: { progress in
                if Task.isCancelled { return false }
                let decoded = progress.text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !decoded.isEmpty {
                    onProgress?("正在设备端离线识别：已生成 (decoded.count) 个字符...")
                }
                return true
            }
        )
        await pipeline.unloadModels()
        self.pipeline = nil
        loadedModel = nil
        try Task.checkCancellation()

        guard let first = results.first else {
            throw NSError(
                domain: "LocalWhisperError",
                code: -2,
                userInfo: [NSLocalizedDescriptionKey: "离线模型没有返回转写结果"]
            )
        }

        let transcriptionResults = try first.get()
        let segments = transcriptionResults
            .flatMap(\.segments)
            .sorted { lhs, rhs in
                if lhs.start == rhs.start { return lhs.end < rhs.end }
                return lhs.start < rhs.start
            }

        var lines: [SubtitleLine] = []
        for segment in segments {
            let text = clean(segment.text)
            guard !text.isEmpty, segment.end > segment.start, segment.noSpeechProb < 0.9 else { continue }

            let candidate = SubtitleLine(
                startTime: TimeInterval(segment.start),
                endTime: TimeInterval(max(segment.end, segment.start + 0.6)),
                originalText: text
            )
            if let last = lines.last,
               abs(last.startTime - candidate.startTime) < 0.35,
               normalized(last.originalText) == normalized(candidate.originalText) {
                continue
            }
            lines.append(candidate)
        }

        guard !lines.isEmpty else {
            throw NSError(
                domain: "LocalWhisperError",
                code: -3,
                userInfo: [NSLocalizedDescriptionKey: "离线模型未检测到清晰人声，请检查音轨语言或改用高精度模型"]
            )
        }
        return lines
    }

    private func clean(_ text: String) -> String {
        text
            .replacingOccurrences(of: "<|[^>]+|>", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func normalized(_ text: String) -> String {
        text.lowercased().filter { !$0.isWhitespace && !$0.isPunctuation }
    }
}
