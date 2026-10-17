import AVFoundation
import CoreML
import Foundation
#if canImport(UIKit)
import UIKit
#endif
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
        case .compact: return "快速 · Base"
        }
    }

    public var detail: String {
        switch self {
        case .highAccuracy: return "推荐日语动漫和影视，准确率最高，首次下载较大"
        case .balanced: return "速度、内存和准确率较均衡"
        case .compact: return "旧设备更稳，速度快，但生词和多人对白准确率较低"
        }
    }

    public var estimatedSizeBytes: Int64 {
        switch self {
        case .highAccuracy: return 626 * 1_024 * 1_024
        case .balanced: return 240 * 1_024 * 1_024
        case .compact: return 74 * 1_024 * 1_024
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

private final class ProgressThrottleBox: @unchecked Sendable {
    private let lock = NSLock()
    private var lastReportTime: TimeInterval = 0

    func shouldReport(minInterval: TimeInterval = 0.45) -> Bool {
        let now = ProcessInfo.processInfo.systemUptime
        lock.lock()
        defer { lock.unlock() }
        guard now - lastReportTime >= minInterval else { return false }
        lastReportTime = now
        return true
    }
}

public actor LocalWhisperSubtitleService {
    public struct ProgressiveUpdate: Sendable {
        public let lines: [SubtitleLine]
        public let completedChunkIndexes: [Int]
        public let totalChunkCount: Int
        public let latestChunkIndex: Int
        public let latestChunkLines: [SubtitleLine]

        public init(
            lines: [SubtitleLine],
            completedChunkIndexes: [Int],
            totalChunkCount: Int,
            latestChunkIndex: Int = -1,
            latestChunkLines: [SubtitleLine] = []
        ) {
            self.lines = lines
            self.completedChunkIndexes = completedChunkIndexes
            self.totalChunkCount = totalChunkCount
            self.latestChunkIndex = latestChunkIndex
            self.latestChunkLines = latestChunkLines
        }
    }

    private var pipeline: WhisperKit?
    private var loadedModel: OfflineWhisperModel?
    public static let chunkDuration: TimeInterval = 4 * 60
    private static let firstPassDuration: TimeInterval = 20
    public static let defaultUsesRelaxedVoiceDetection = false
    public static let previewUsesRelaxedVoiceDetection = true

    private var computeDescription = "系统默认配置"
    private var activeTranscriptionCount: Int = 0
    private var idleUnloadTask: Task<Void, Never>?
    private var memoryWarningObserver: (any NSObjectProtocol)?
    private let idleUnloadDelayNanoseconds: UInt64 = 180 * 1_000_000_000

    public init() {}

    deinit {
        #if canImport(UIKit)
        if let memoryWarningObserver {
            NotificationCenter.default.removeObserver(memoryWarningObserver)
        }
        #endif
        idleUnloadTask?.cancel()
    }

    #if canImport(UIKit)
    private func setupMemoryWarningObserverIfNeeded() {
        guard memoryWarningObserver == nil else { return }
        memoryWarningObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            guard let self else { return }
            Task { [weak self] in
                await self?.unloadIfIdle()
            }
        }
    }
    #else
    private func setupMemoryWarningObserverIfNeeded() {}
    #endif

    public func unloadIfIdle() async {
        guard activeTranscriptionCount <= 0 else { return }
        idleUnloadTask?.cancel()
        idleUnloadTask = nil
        if let pipeline {
            await pipeline.unloadModels()
            self.pipeline = nil
            loadedModel = nil
        }
    }

    private func scheduleIdleUnload() {
        idleUnloadTask?.cancel()
        let delay = idleUnloadDelayNanoseconds
        idleUnloadTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: delay)
            guard !Task.isCancelled else { return }
            await self?.unloadIfIdle()
        }
    }

    private func startSliceExportTask(
        mediaURL: URL,
        sourceLanguage: SubtitleSourceLanguage,
        start: TimeInterval,
        duration: TimeInterval
    ) -> Task<URL, Error> {
        Task {
            try Task.checkCancellation()
            let sliceURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("lovort-local-\(UUID().uuidString).m4a")
            do {
                try await self.exportAudioSlice(
                    mediaURL: mediaURL,
                    sourceLanguage: sourceLanguage,
                    start: start,
                    duration: duration,
                    outputURL: sliceURL
                )
                return sliceURL
            } catch {
                try? FileManager.default.removeItem(at: sliceURL)
                throw error
            }
        }
    }

    public func transcribe(
        audioURL: URL,
        sourceLanguage: SubtitleSourceLanguage,
        model: OfflineWhisperModel,
        preferredStartTime: TimeInterval = 0,
        existingLines: [SubtitleLine] = [],
        completedChunkIndexes: Set<Int> = [],
        useRelaxedVoiceDetection: Bool = defaultUsesRelaxedVoiceDetection,
        onProgress: (@Sendable (String) -> Void)? = nil,
        onPartialResult: (@Sendable (ProgressiveUpdate) async -> Void)? = nil
    ) async throws -> [SubtitleLine] {
        try await transcribeProgressively(
            audioURL: audioURL,
            sourceLanguage: sourceLanguage,
            model: model,
            preferredStartTime: preferredStartTime,
            existingLines: existingLines,
            completedChunkIndexes: completedChunkIndexes,
            useRelaxedVoiceDetection: useRelaxedVoiceDetection,
            onProgress: onProgress,
            onPartialResult: { update in
                await onPartialResult?(update)
                return nil
            }
        )
    }

    func transcribeProgressively(
        audioURL: URL,
        sourceLanguage: SubtitleSourceLanguage,
        model: OfflineWhisperModel,
        preferredStartTime: TimeInterval = 0,
        existingLines: [SubtitleLine] = [],
        completedChunkIndexes: Set<Int> = [],
        useRelaxedVoiceDetection: Bool = defaultUsesRelaxedVoiceDetection,
        onProgress: (@Sendable (String) -> Void)? = nil,
        onEvent: (@Sendable (SubtitleProgressEvent) -> Void)? = nil,
        onPartialResult: (@Sendable (ProgressiveUpdate) async -> [SubtitleLine]?)? = nil
    ) async throws -> [SubtitleLine] {
        let transcriptionStarted = Date()
        // Actor methods may interleave at every await. Keep WhisperKit's mutable
        // pipeline exclusive when a preview and a full task arrive together.
        while activeTranscriptionCount > 0 {
            onEvent?(.phase(.waitingForModel))
            try Task.checkCancellation()
            try await Task.sleep(nanoseconds: 150_000_000)
        }
        onEvent?(.phase(.waitingForModel))
        setupMemoryWarningObserverIfNeeded()
        idleUnloadTask?.cancel()
        idleUnloadTask = nil
        activeTranscriptionCount += 1
        defer {
            activeTranscriptionCount = max(0, activeTranscriptionCount - 1)
            if activeTranscriptionCount == 0 {
                scheduleIdleUnload()
            }
        }

        if pipeline == nil || loadedModel != model {
            let alreadyInstalled = await OfflineWhisperModelManager.shared.installedFolder(for: model) != nil
            if alreadyInstalled {
                onProgress?("正在加载离线模型 \(model.displayName)...")
            } else {
                onProgress?("正在准备离线模型（首次使用需联网下载 \(model.displayName)）...")
            }
            let modelFolder = try await OfflineWhisperModelManager.shared.prepare(model)
            try Task.checkCancellation()

            let prewarmKey = "LovortWhisperPrewarmed.\(model.rawValue)"
            let shouldPrewarm = !(alreadyInstalled && UserDefaults.standard.bool(forKey: prewarmKey))

            let loadingStarted = Date()
            computeDescription = "系统默认配置"
            var loadedPipeline: WhisperKit?
            do {
                loadedPipeline = try await WhisperKit(
                    WhisperKitConfig(
                        model: model.rawValue,
                        modelFolder: modelFolder.path,
                        verbose: false,
                        prewarm: shouldPrewarm,
                        load: true,
                        download: false,
                        useBackgroundDownloadSession: false
                    )
                )
            } catch {
                // 如果默认配置加载失败（如 ANE / CoreML 神经引擎读取报错），尝试回退到 GPU + CPU 兼容模式
                computeDescription = "CPU + GPU 兼容回退"
                let fallbackCompute = ModelComputeOptions(
                    melCompute: .cpuAndGPU,
                    audioEncoderCompute: .cpuAndGPU,
                    textDecoderCompute: .cpuAndGPU
                )
                do {
                    loadedPipeline = try await WhisperKit(
                        WhisperKitConfig(
                            model: model.rawValue,
                            modelFolder: modelFolder.path,
                            computeOptions: fallbackCompute,
                            verbose: false,
                            prewarm: shouldPrewarm,
                            load: true,
                            download: false,
                            useBackgroundDownloadSession: false
                        )
                    )
                } catch let loadError {
                    UserDefaults.standard.removeObject(forKey: prewarmKey)
                    // A CoreML load failure can also mean memory pressure or an unsupported
                    // compute unit. Keep the installed files so the user can retry offline.
                    throw NSError(
                        domain: "LocalWhisperError",
                        code: -2,
                        userInfo: [NSLocalizedDescriptionKey: "离线模型加载失败：\(loadError.localizedDescription)。模型文件已保留，可重试或切换模型"]
                    )
                }
            }

            UserDefaults.standard.set(true, forKey: prewarmKey)
            await SubtitlePerformanceLog.shared.record(stage: "模型加载", model: model.rawValue, seconds: Date().timeIntervalSince(loadingStarted), backend: computeDescription)
            pipeline = loadedPipeline
            loadedModel = model
        }

        guard let pipeline else {
            throw NSError(
                domain: "LocalWhisperError",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "离线语音模型加载失败"]
            )
        }

        try Task.checkCancellation()
        let sourceAsset = AVURLAsset(url: audioURL)
        let tracks = try await sourceAsset.loadTracks(withMediaType: .audio)
        guard !tracks.isEmpty else { throw serviceError("视频中没有可用音轨") }
        let selectedTrack = AudioTrackSelection.orderedTracks(tracks, sourceLanguage: sourceLanguage)[0]
        let trackRange = try await selectedTrack.load(.timeRange)
        let duration = CMTimeGetSeconds(trackRange.duration)
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
        var resolvedLanguageCode = sourceLanguage.whisperCode
        var recordedFirstCaption = !existingLines.isEmpty

        if let onPartialResult {
            let initialLines = await onPartialResult(ProgressiveUpdate(
                lines: lines,
                completedChunkIndexes: completed.sorted(),
                totalChunkCount: totalChunks,
                latestChunkIndex: -1,
                latestChunkLines: []
            ))
            if let initialLines, !initialLines.isEmpty {
                lines = initialLines
            }
        }

        var prefetchedTask: Task<URL, Error>?
        if let firstChunk = pendingChunks.first {
            let start = TimeInterval(firstChunk) * Self.chunkDuration
            let sliceDuration = min(Self.chunkDuration, duration - start)
            prefetchedTask = startSliceExportTask(
                mediaURL: audioURL,
                sourceLanguage: sourceLanguage,
                start: start,
                duration: Self.firstSliceDuration(sliceDuration)
            )
        }

        defer {
            if let task = prefetchedTask {
                task.cancel()
                Task {
                    if let leftoverURL = try? await task.value {
                        try? FileManager.default.removeItem(at: leftoverURL)
                    }
                }
            }
        }

        for (orderOffset, chunkIndex) in pendingChunks.enumerated() {
            try Task.checkCancellation()
            let start = TimeInterval(chunkIndex) * Self.chunkDuration
            let sliceDuration = min(Self.chunkDuration, duration - start)
            let splitFirst = orderOffset == 0 && Self.firstSliceDuration(sliceDuration) < sliceDuration

            let currentTask = prefetchedTask ?? startSliceExportTask(
                mediaURL: audioURL,
                sourceLanguage: sourceLanguage,
                start: start,
                duration: splitFirst ? Self.firstPassDuration : sliceDuration
            )
            prefetchedTask = nil

            onEvent?(.phase(.preparingAudio))
            let extractionStarted = Date()
            let sliceURL = try await currentTask.value
            await SubtitlePerformanceLog.shared.record(stage: "切片等待（含预取）", model: model.rawValue, seconds: Date().timeIntervalSince(extractionStarted))
            defer {
                try? FileManager.default.removeItem(at: sliceURL)
            }
            try Task.checkCancellation()

            onProgress?("正在离线生成第 \(completed.count + 1)/\(totalChunks) 个字幕分片...")
            onEvent?(.transcription(completed: completed.count, total: totalChunks))
            var prefixLines: [SubtitleLine] = []
            if splitFirst {
                let prefix = try await transcribeSingleAudio(pipeline: pipeline, audioURL: sliceURL, languageCode: resolvedLanguageCode,
                    offset: start, chunkNumber: completed.count + 1, totalChunks: totalChunks,
                    useRelaxedVoiceDetection: useRelaxedVoiceDetection, onProgress: onProgress,
                    clipRange: 0...Float(Self.firstPassDuration))
                prefixLines = prefix.lines
                if resolvedLanguageCode == nil, !prefix.lines.isEmpty { resolvedLanguageCode = prefix.detectedLanguage }
                lines.removeAll { $0.startTime >= start && $0.startTime < start + sliceDuration }
                lines.append(contentsOf: prefixLines)
                lines.sort { $0.startTime < $1.startTime }
                if let onPartialResult, let merged = await onPartialResult(ProgressiveUpdate(lines: lines, completedChunkIndexes: completed.sorted(), totalChunkCount: totalChunks, latestChunkIndex: chunkIndex, latestChunkLines: prefixLines)) {
                    lines = merged
                    prefixLines = merged.filter { $0.startTime >= start && $0.startTime < start + Self.firstPassDuration }
                }
                if !recordedFirstCaption, !prefixLines.isEmpty {
                    recordedFirstCaption = true
                    await SubtitlePerformanceLog.shared.record(stage: "首条原文产出", model: model.rawValue,
                        seconds: Date().timeIntervalSince(transcriptionStarted))
                }
            }
            var remainingURL: URL?
            defer { if let remainingURL { try? FileManager.default.removeItem(at: remainingURL) } }
            if splitFirst {
                let output = FileManager.default.temporaryDirectory.appendingPathComponent("lovort-remainder-\(UUID().uuidString).m4a")
                remainingURL = output
                let remainingStarted = Date()
                try await exportAudioSlice(mediaURL: audioURL, sourceLanguage: sourceLanguage,
                    start: start + Self.firstPassDuration, duration: sliceDuration - Self.firstPassDuration, outputURL: output)
                try Task.checkCancellation()
                await SubtitlePerformanceLog.shared.record(stage: "首片剩余音频提取", model: model.rawValue,
                    seconds: Date().timeIntervalSince(remainingStarted))
            }

            let nextOffset = orderOffset + 1
            if nextOffset < pendingChunks.count {
                let nextChunk = pendingChunks[nextOffset]
                let nextStart = TimeInterval(nextChunk) * Self.chunkDuration
                let nextSliceDuration = min(Self.chunkDuration, duration - nextStart)
                prefetchedTask = startSliceExportTask(
                    mediaURL: audioURL,
                    sourceLanguage: sourceLanguage,
                    start: nextStart,
                    duration: nextSliceDuration
                )
            }
            let chunkResult = try await transcribeSingleAudio(
                pipeline: pipeline,
                audioURL: remainingURL ?? sliceURL,
                languageCode: resolvedLanguageCode,
                offset: start + (splitFirst ? Self.firstPassDuration : 0),
                chunkNumber: completed.count + 1,
                totalChunks: totalChunks,
                useRelaxedVoiceDetection: useRelaxedVoiceDetection,
                onProgress: onProgress
            )

            if resolvedLanguageCode == nil, !chunkResult.lines.isEmpty,
               let detected = chunkResult.detectedLanguage, !detected.isEmpty {
                resolvedLanguageCode = detected
            }

            let chunkLines = prefixLines + chunkResult.lines
            if !recordedFirstCaption, !chunkLines.isEmpty {
                recordedFirstCaption = true
                await SubtitlePerformanceLog.shared.record(stage: "首条原文产出", model: model.rawValue,
                    seconds: Date().timeIntervalSince(transcriptionStarted))
            }
            let rangeEnd = start + sliceDuration
            lines.removeAll { $0.startTime >= start && $0.startTime < rangeEnd }
            lines.append(contentsOf: chunkLines)
            lines.sort { $0.startTime < $1.startTime }
            completed.insert(chunkIndex)
            onEvent?(.transcription(completed: completed.count, total: totalChunks))

            if let onPartialResult {
                let returnedLines = await onPartialResult(ProgressiveUpdate(
                    lines: lines,
                    completedChunkIndexes: completed.sorted(),
                    totalChunkCount: totalChunks,
                    latestChunkIndex: chunkIndex,
                    latestChunkLines: chunkLines
                ))
                if let returnedLines, !returnedLines.isEmpty {
                    lines = returnedLines
                }
            }
        }

        guard !lines.isEmpty else { throw serviceError("离线模型未检测到清晰人声，请检查音轨语言或改用高精度模型") }
        await SubtitlePerformanceLog.shared.record(stage: "本次原文转写", model: model.rawValue,
            seconds: Date().timeIntervalSince(transcriptionStarted))
        return lines
    }

    static func firstSliceDuration(_ duration: TimeInterval) -> TimeInterval {
        duration > firstPassDuration + 5 ? firstPassDuration : duration
    }

    private func transcribeSingleAudio(
        pipeline: WhisperKit,
        audioURL: URL,
        languageCode: String?,
        offset: TimeInterval,
        chunkNumber: Int,
        totalChunks: Int,
        useRelaxedVoiceDetection: Bool,
        onProgress: (@Sendable (String) -> Void)?,
        clipRange: ClosedRange<Float>? = nil
    ) async throws -> (lines: [SubtitleLine], detectedLanguage: String?) {
        let started = Date()
        let requestedWorkers = UserDefaults.standard.integer(forKey: "subtitle.workers")
        let workers = ProcessInfo.processInfo.thermalState.rawValue >= ProcessInfo.ThermalState.serious.rawValue ? 1 : ([1, 2, 4].contains(requestedWorkers) ? requestedWorkers : 4)
        let options = DecodingOptions(
            task: .transcribe,
            language: languageCode,
            detectLanguage: languageCode == nil,
            skipSpecialTokens: true,
            wordTimestamps: false,
            clipTimestamps: clipRange.map { [$0.lowerBound, $0.upperBound] } ?? [],
            noSpeechThreshold: useRelaxedVoiceDetection ? nil : 0.6,
            concurrentWorkerCount: workers,
            chunkingStrategy: useRelaxedVoiceDetection || clipRange != nil ? ChunkingStrategy.none : .vad
        )
        let throttle = ProgressThrottleBox()
        let inputOptions = AudioInputOptions(channelMode: .sumChannels(nil), audioLoadingMode: .fullFile)
        let results = await pipeline.transcribeWithResults(
            audioPaths: [audioURL.path],
            audioInputOptions: inputOptions,
            decodeOptions: options,
            callback: { progress in
                if Task.isCancelled { return false }
                let decoded = progress.text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !decoded.isEmpty, throttle.shouldReport(minInterval: 0.45) {
                    onProgress?("正在设备端识别 (第 \(chunkNumber)/\(totalChunks) 分片): 已识别 \(decoded.count) 字...")
                }
                return true
            }
        )
        await SubtitlePerformanceLog.shared.record(stage: "离线转写", model: loadedModel?.rawValue ?? "", seconds: Date().timeIntervalSince(started), workers: workers, backend: computeDescription)
        try Task.checkCancellation()
        guard let first = results.first else { throw serviceError("离线模型没有返回转写结果") }
        let transcriptionResults = try first.get()
        await SubtitlePerformanceLog.shared.record(stage: "音频读入", model: loadedModel?.rawValue ?? "", seconds: transcriptionResults.reduce(0) { $0 + $1.timings.audioLoading })
        await SubtitlePerformanceLog.shared.record(stage: "编码推理", model: loadedModel?.rawValue ?? "", seconds: transcriptionResults.reduce(0) { $0 + $1.timings.encoding })
        await SubtitlePerformanceLog.shared.record(stage: "解码与重试", model: loadedModel?.rawValue ?? "", seconds: transcriptionResults.reduce(0) { $0 + $1.timings.decodingLoop }, workers: workers)
        let detectedLanguage: String? = transcriptionResults.first?.language
        let segments = transcriptionResults.flatMap(\.segments).sorted { $0.start < $1.start }
        var lines: [SubtitleLine] = []
        for segment in segments {
            let text = clean(segment.text)
            guard !text.isEmpty,
                  segment.end > segment.start,
                  (useRelaxedVoiceDetection || segment.noSpeechProb < 0.9)
            else { continue }
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
        return (lines: lines, detectedLanguage: detectedLanguage)
    }

    func exportAudioSlice(
        mediaURL: URL,
        sourceLanguage: SubtitleSourceLanguage,
        start: TimeInterval,
        duration: TimeInterval,
        outputURL: URL
    ) async throws {
        let sourceAsset = AVURLAsset(url: mediaURL)
        let tracks = try await sourceAsset.loadTracks(withMediaType: .audio)
        guard !tracks.isEmpty else { throw serviceError("视频中没有可用音轨") }
        let selectedTrack = AudioTrackSelection.orderedTracks(tracks, sourceLanguage: sourceLanguage)[0]

        let trackRange = try await selectedTrack.load(.timeRange)
        let trackStartSeconds = CMTimeGetSeconds(trackRange.start)
        let safeTrackStart = trackStartSeconds.isFinite ? max(0, trackStartSeconds) : 0
        let sliceStartCM = CMTime(seconds: safeTrackStart + start, preferredTimescale: 600)
        let requestedDurationCM = CMTime(seconds: duration, preferredTimescale: 600)
        let trackEndCM = CMTimeAdd(trackRange.start, trackRange.duration)
        let availableDurationCM = CMTimeSubtract(trackEndCM, sliceStartCM)
        let finalDurationCM = CMTimeMinimum(requestedDurationCM, availableDurationCM)
        guard finalDurationCM > .zero else { throw serviceError("音频分片范围超出有效音轨") }

        let sliceTimeRange = CMTimeRange(start: sliceStartCM, duration: finalDurationCM)
        let composition = AVMutableComposition()
        guard let compositionTrack = composition.addMutableTrack(
            withMediaType: .audio,
            preferredTrackID: kCMPersistentTrackID_Invalid
        ) else { throw serviceError("无法创建离线音频轨道") }
        try compositionTrack.insertTimeRange(sliceTimeRange, of: selectedTrack, at: .zero)

        guard let exportSession = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetAppleM4A) else {
            throw serviceError("无法创建离线音频分片")
        }
        try? FileManager.default.removeItem(at: outputURL)
        try await exportSession.export(to: outputURL, as: .m4a)
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
            .replacingOccurrences(of: #"<\|[^>|]+\|>"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func normalized(_ text: String) -> String {
        text.lowercased().filter { !$0.isWhitespace && !$0.isPunctuation }
    }
}
