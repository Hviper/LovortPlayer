import AVFoundation
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
    public struct ProgressiveUpdate: Sendable {
        public let lines: [SubtitleLine]
        public let completedChunkIndexes: [Int]
        public let totalChunkCount: Int
    }

    private var pipeline: WhisperKit?
    private var loadedModel: OfflineWhisperModel?
    public static let chunkDuration: TimeInterval = 4 * 60

    public init() {}

    public func transcribe(
        audioURL: URL,
        sourceLanguage: SubtitleSourceLanguage,
        model: OfflineWhisperModel,
        preferredStartTime: TimeInterval = 0,
        existingLines: [SubtitleLine] = [],
        completedChunkIndexes: Set<Int> = [],
        onProgress: (@Sendable (String) -> Void)? = nil,
        onPartialResult: (@Sendable (ProgressiveUpdate) async -> Void)? = nil
    ) async throws -> [SubtitleLine] {
        if pipeline == nil || loadedModel != model {
            onProgress?("正在准备离线模型（首次使用需联网下载 \(model.displayName)）...")
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

        do {
            let asset = try await makeAudioComposition(from: audioURL, sourceLanguage: sourceLanguage)
            let durationValue = try await asset.load(.duration)
            let duration = CMTimeGetSeconds(durationValue)
            guard duration.isFinite, duration > 0 else { throw serviceError("无法读取音频时长") }

            let totalChunks = max(1, Int(ceil(duration / Self.chunkDuration)))
            let preferredChunk = max(0, min(totalChunks - 1, Int(preferredStartTime / Self.chunkDuration)))
            let pendingChunks = Self.chunkProcessingOrder(
                totalChunks: totalChunks,
                preferredChunk: preferredChunk,
                completed: completedChunkIndexes
            )

            var lines = existingLines
            var completed = completedChunkIndexes
            for chunkIndex in pendingChunks {
                try Task.checkCancellation()
                let start = TimeInterval(chunkIndex) * Self.chunkDuration
                let sliceDuration = min(Self.chunkDuration, duration - start)
                let sliceURL = FileManager.default.temporaryDirectory
                    .appendingPathComponent("lovort-local-\(UUID().uuidString).m4a")
                try await exportAudioSlice(asset: asset, start: start, duration: sliceDuration, outputURL: sliceURL)
                defer {
                    try? FileManager.default.removeItem(at: sliceURL)
                }

                onProgress?("正在离线生成第 \(completed.count + 1)/\(totalChunks) 个字幕分片...")
                let chunkLines = try await transcribeSingleAudio(
                    pipeline: pipeline,
                    audioURL: sliceURL,
                    sourceLanguage: sourceLanguage,
                    offset: start,
                    onProgress: onProgress
                )
                let rangeEnd = start + sliceDuration
                lines.removeAll { $0.startTime >= start && $0.startTime < rangeEnd }
                lines.append(contentsOf: chunkLines)
                lines.sort { $0.startTime < $1.startTime }
                completed.insert(chunkIndex)
                if let onPartialResult {
                    await onPartialResult(ProgressiveUpdate(
                        lines: lines,
                        completedChunkIndexes: completed.sorted(),
                        totalChunkCount: totalChunks
                    ))
                }
            }

            await pipeline.unloadModels()
            self.pipeline = nil
            loadedModel = nil
            guard !lines.isEmpty else { throw serviceError("离线模型未检测到清晰人声，请检查音轨语言或改用高精度模型") }
            return lines
        } catch {
            await pipeline.unloadModels()
            self.pipeline = nil
            loadedModel = nil
            throw error
        }
    }

    private func transcribeSingleAudio(
        pipeline: WhisperKit,
        audioURL: URL,
        sourceLanguage: SubtitleSourceLanguage,
        offset: TimeInterval,
        onProgress: (@Sendable (String) -> Void)?
    ) async throws -> [SubtitleLine] {
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
        let inputOptions = AudioInputOptions(channelMode: .sumChannels(nil), audioLoadingMode: .incremental)
        let results = await pipeline.transcribeWithResults(
            audioPaths: [audioURL.path],
            audioInputOptions: inputOptions,
            decodeOptions: options,
            callback: { progress in
                if Task.isCancelled { return false }
                let decoded = progress.text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !decoded.isEmpty { onProgress?("正在设备端识别：已生成 \(decoded.count) 个字符...") }
                return true
            }
        )
        try Task.checkCancellation()
        guard let first = results.first else { throw serviceError("离线模型没有返回转写结果") }
        let segments = try first.get().flatMap(\.segments).sorted { $0.start < $1.start }
        var lines: [SubtitleLine] = []
        for segment in segments {
            let text = clean(segment.text)
            guard !text.isEmpty, segment.end > segment.start, segment.noSpeechProb < 0.9 else { continue }
            let candidate = SubtitleLine(
                startTime: TimeInterval(segment.start) + offset,
                endTime: TimeInterval(max(segment.end, segment.start + 0.6)) + offset,
                originalText: text
            )
            if let last = lines.last,
               abs(last.startTime - candidate.startTime) < 0.35,
               normalized(last.originalText) == normalized(candidate.originalText) { continue }
            lines.append(candidate)
        }
        return lines
    }

    private func makeAudioComposition(
        from mediaURL: URL,
        sourceLanguage: SubtitleSourceLanguage
    ) async throws -> AVMutableComposition {
        let sourceAsset = AVURLAsset(url: mediaURL)
        let tracks = try await sourceAsset.loadTracks(withMediaType: .audio)
        guard !tracks.isEmpty else { throw serviceError("视频中没有可用音轨") }
        let candidates = sourceLanguage.trackLanguageCandidates
        let selectedTrack = tracks.first { track in
            let tag = (track.extendedLanguageTag ?? track.languageCode ?? "").lowercased()
            return candidates.contains { tag == $0 || tag.hasPrefix("\($0)-") }
        } ?? tracks[0]
        let timeRange = try await selectedTrack.load(.timeRange)
        let composition = AVMutableComposition()
        guard let compositionTrack = composition.addMutableTrack(
            withMediaType: .audio,
            preferredTrackID: kCMPersistentTrackID_Invalid
        ) else { throw serviceError("无法创建离线音频轨道") }
        try compositionTrack.insertTimeRange(timeRange, of: selectedTrack, at: .zero)
        return composition
    }

    private func exportAudioSlice(asset: AVAsset, start: TimeInterval, duration: TimeInterval, outputURL: URL) async throws {
        guard let exportSession = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
            throw serviceError("无法创建离线音频分片")
        }
        try? FileManager.default.removeItem(at: outputURL)
        exportSession.outputURL = outputURL
        exportSession.outputFileType = .m4a
        exportSession.timeRange = CMTimeRange(
            start: CMTime(seconds: start, preferredTimescale: 600),
            duration: CMTime(seconds: duration, preferredTimescale: 600)
        )
        await exportSession.export()
        guard exportSession.status == .completed else {
            throw exportSession.error ?? serviceError("离线音频分片导出失败")
        }
    }

    private func serviceError(_ message: String) -> NSError {
        NSError(domain: "LocalWhisperError", code: -1, userInfo: [NSLocalizedDescriptionKey: message])
    }

    static func chunkProcessingOrder(totalChunks: Int, preferredChunk: Int, completed: Set<Int>) -> [Int] {
        guard totalChunks > 0 else { return [] }
        let preferred = max(0, min(totalChunks - 1, preferredChunk))
        return (0..<totalChunks)
            .filter { !completed.contains($0) }
            .sorted {
                let lhsDistance = abs($0 - preferred)
                let rhsDistance = abs($1 - preferred)
                return lhsDistance == rhsDistance ? $0 < $1 : lhsDistance < rhsDistance
            }
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
