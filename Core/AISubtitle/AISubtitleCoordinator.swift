import AVFoundation
import Foundation
import Security

public enum AISubtitleEngineType: String, CaseIterable, Codable, Identifiable, Sendable {
    case localWhisperKit
    case cloudOpenAI
    case cloudAntigravity

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .localWhisperKit: return "离线 WhisperKit（推荐）"
        case .cloudOpenAI: return "OpenAI API 云端转写"
        case .cloudAntigravity: return "Antigravity 云端转写"
        }
    }
}

public struct SubtitlePreviewResult: Sendable {
    public let startTime: TimeInterval
    public let endTime: TimeInterval
    public let elapsedTime: TimeInterval
    public let audioTrackDescription: String
    public let lines: [SubtitleLine]
    public let translationWarning: String?
}

public final class AISubtitleCoordinator: @unchecked Sendable {
    public static let shared = AISubtitleCoordinator()

    public var isEnabled: Bool = false
    public var currentEngine: AISubtitleEngineType {
        didSet { UserDefaults.standard.set(currentEngine.rawValue, forKey: engineStorageKey) }
    }
    public var offlineModel: OfflineWhisperModel {
        didSet { UserDefaults.standard.set(offlineModel.rawValue, forKey: modelStorageKey) }
    }
    public var translationProvider: SubtitleTranslationProviderType {
        didSet { UserDefaults.standard.set(translationProvider.rawValue, forKey: translationProviderStorageKey) }
    }
    public var isGPTEnhancementEnabled: Bool {
        didSet { UserDefaults.standard.set(isGPTEnhancementEnabled, forKey: gptEnhancementStorageKey) }
    }

    private let openAIKeyStorageKey = "LovortOpenAIAPIKey"
    private let openAIKeychainService = "com.hviper.lovortplayer.openai-platform-key"
    private let engineStorageKey = "LovortSubtitleEngine"
    private let modelStorageKey = "LovortOfflineWhisperModel"
    private let translationProviderStorageKey = "LovortTranslationProvider"
    private let gptEnhancementStorageKey = "LovortGPTSubtitleEnhancement"
    private let localService = LocalWhisperSubtitleService()
    private let cacheStore = SubtitleCacheStore()

    private init() {
        let engineValue = UserDefaults.standard.string(forKey: engineStorageKey) ?? ""
        currentEngine = AISubtitleEngineType(rawValue: engineValue) ?? .localWhisperKit
        let modelValue = UserDefaults.standard.string(forKey: modelStorageKey) ?? ""
        offlineModel = OfflineWhisperModel(rawValue: modelValue) ?? .balanced
        let providerValue = UserDefaults.standard.string(forKey: translationProviderStorageKey) ?? ""
        translationProvider = SubtitleTranslationProviderType(rawValue: providerValue) ?? .apple
        isGPTEnhancementEnabled = UserDefaults.standard.bool(forKey: gptEnhancementStorageKey)
    }

    public func getSavedOpenAIKey() -> String {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: openAIKeychainService,
            kSecAttrAccount as String: openAIKeyStorageKey,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        if SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
           let data = result as? Data,
           let value = String(data: data, encoding: .utf8) {
            return value
        }

        let legacy = UserDefaults.standard.string(forKey: openAIKeyStorageKey) ?? ""
        if legacy.hasPrefix("sk-") {
            saveOpenAIKey(legacy)
            return legacy
        }
        return ""
    }

    public func saveOpenAIKey(_ key: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: openAIKeychainService,
            kSecAttrAccount as String: openAIKeyStorageKey
        ]
        SecItemDelete(query as CFDictionary)
        UserDefaults.standard.removeObject(forKey: openAIKeyStorageKey)
        guard !key.isEmpty else { return }
        var item = query
        item[kSecValueData as String] = Data(key.utf8)
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(item as CFDictionary, nil)
    }

    public func extractAudioTrack(
        from videoURL: URL,
        outputAudioURL: URL,
        sourceLanguage: SubtitleSourceLanguage
    ) async throws {
        let asset = AVURLAsset(url: videoURL)
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        guard !tracks.isEmpty else {
            throw NSError(
                domain: "AudioExtractError",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "视频中没有可用音轨"]
            )
        }

        let selectedTrack = AudioTrackSelection.orderedTracks(
            tracks,
            sourceLanguage: sourceLanguage
        )[0]

        let composition = AVMutableComposition()
        guard let compositionTrack = composition.addMutableTrack(
            withMediaType: .audio,
            preferredTrackID: kCMPersistentTrackID_Invalid
        ) else {
            throw NSError(
                domain: "AudioExtractError",
                code: -2,
                userInfo: [NSLocalizedDescriptionKey: "无法创建音频轨道"]
            )
        }
        let timeRange = try await selectedTrack.load(.timeRange)
        try compositionTrack.insertTimeRange(timeRange, of: selectedTrack, at: .zero)

        guard let exportSession = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetAppleM4A) else {
            throw NSError(
                domain: "AudioExtractError",
                code: -3,
                userInfo: [NSLocalizedDescriptionKey: "无法创建音频导出会话"]
            )
        }
        try? FileManager.default.removeItem(at: outputAudioURL)
        exportSession.outputURL = outputAudioURL
        exportSession.outputFileType = .m4a
        await exportSession.export()
        guard exportSession.status == .completed else {
            throw exportSession.error ?? NSError(
                domain: "AudioExtractError",
                code: -4,
                userInfo: [NSLocalizedDescriptionKey: "音轨导出失败"]
            )
        }
    }

    public func loadLocalSRTIfAvailable(for videoURL: URL) -> [SubtitleLine]? {
        if let cached = cacheStore.load(for: videoURL) { return cached.lines }

        let base = videoURL.deletingPathExtension()
        let candidates = [
            base.appendingPathExtension("srt"),
            base.appendingPathExtension("zh.srt"),
            base.appendingPathExtension("ja.srt"),
            base.appendingPathExtension("en.srt")
        ]
        for url in candidates {
            guard FileManager.default.fileExists(atPath: url.path),
                  let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            let lines = SRTParser.parse(srtString: text)
            if !lines.isEmpty { return lines }
        }
        return nil
    }

    private static func persist(_ document: SubtitleDocument, for url: URL, store: SubtitleCacheStore, permit: SubtitleRunPermit?) throws -> URL {
        if let permit { return try permit.perform { try store.save(document, for: url) } }
        try Task.checkCancellation()
        return try store.save(document, for: url)
    }

    public func processVideo(
        videoURL: URL,
        targetLanguage: String = "中文 (简体)",
        sourceLanguage: SubtitleSourceLanguage = .automatic,
        engine: AISubtitleEngineType? = nil,
        model: OfflineWhisperModel? = nil,
        translationProvider: SubtitleTranslationProviderType? = nil,
        enhanceWithGPT: Bool? = nil,
        preferredStartTime: TimeInterval = 0,
        forceRegenerate: Bool = false,
        onProgress: (@Sendable (String) -> Void)? = nil,
        onTranscriptionProgress: (@Sendable (_ completedChunks: Int, _ totalChunks: Int) async -> Void)? = nil,
        onPartialResult: (@Sendable ([SubtitleLine]) async -> Void)? = nil,
        onEvent: (@Sendable (SubtitleProgressEvent) -> Void)? = nil,
        cachePermit: SubtitleRunPermit? = nil
    ) async throws -> [SubtitleLine] {
        let privateVideo = videoURL.pathExtension == "vault" || videoURL.path.contains("/.Vault/")
        if privateVideo, !(await VaultManager.shared.isUnlocked) { throw NSError(domain: "Subtitle", code: 1, userInfo: [NSLocalizedDescriptionKey: "请先解锁保险箱"]) }
        let selectedEngine = engine ?? currentEngine
        let selectedModel = model ?? offlineModel
        let selectedTranslationProvider = effectiveTranslationProvider(translationProvider ?? self.translationProvider)
        let translationSettings = TranslationAPISettings(provider: selectedTranslationProvider)
        let shouldEnhanceWithGPT = enhanceWithGPT ?? isGPTEnhancementEnabled

        let cachedDocument = cacheStore.load(for: videoURL)
        let expectedModel = selectedEngine == .localWhisperKit ? selectedModel.rawValue : nil
        if !forceRegenerate {
            if let cachedDocument,
               cachedDocument.isComplete != false,
               cachedDocument.sourceLanguage == sourceLanguage.rawValue,
               cachedDocument.targetLanguage == targetLanguage,
               cachedDocument.engine == selectedEngine,
               cachedDocument.model == expectedModel,
               cachedDocument.translationProvider == selectedTranslationProvider,
               cachedDocument.translationConfiguration == translationSettings.cacheIdentity,
               cachedDocument.translationComplete != false,
               (cachedDocument.gptEnhanced ?? false) == (selectedTranslationProvider == .openAI || shouldEnhanceWithGPT) {
                onProgress?("已加载匹配当前配置的本地字幕（共 \(cachedDocument.lines.count) 句）")
                return cachedDocument.lines
            }
            if cachedDocument == nil, let external = loadLocalSRTIfAvailable(for: videoURL) {
                onProgress?("已加载视频同目录字幕（共 \(external.count) 句）")
                return external
            }
        }

        let reusableOriginalLines: [SubtitleLine]? = {
            guard !forceRegenerate,
                  let cachedDocument,
                  cachedDocument.isComplete != false,
                  cachedDocument.sourceLanguage == sourceLanguage.rawValue,
                  cachedDocument.engine == selectedEngine,
                  cachedDocument.model == expectedModel else { return nil }
            let keepTranslations = cachedDocument.translationConfiguration == translationSettings.cacheIdentity
                && cachedDocument.translationProvider == selectedTranslationProvider
                && cachedDocument.targetLanguage == targetLanguage
            return cachedDocument.lines.map {
                SubtitleLine(
                    id: $0.id,
                    startTime: $0.startTime,
                    endTime: $0.endTime,
                    originalText: $0.originalText,
                    translatedText: keepTranslations ? $0.translatedText : nil
                )
            }
        }()

        let resumableDocument: SubtitleDocument? = {
            guard selectedEngine == .localWhisperKit,
                  let cachedDocument,
                  cachedDocument.isComplete == false,
                  cachedDocument.sourceLanguage == sourceLanguage.rawValue,
                  cachedDocument.engine == selectedEngine,
                  cachedDocument.model == expectedModel else { return nil }
            return cachedDocument
        }()

        let initialLines: [SubtitleLine] = {
            guard let resumableDocument else { return [] }
            let keepTranslations = resumableDocument.translationConfiguration == translationSettings.cacheIdentity
                && resumableDocument.translationProvider == selectedTranslationProvider
                && resumableDocument.targetLanguage == targetLanguage
            if keepTranslations {
                return resumableDocument.lines
            } else {
                return resumableDocument.lines.map {
                    SubtitleLine(id: $0.id, startTime: $0.startTime, endTime: $0.endTime, originalText: $0.originalText)
                }
            }
        }()

        let platformKey = getSavedOpenAIKey().trimmingCharacters(in: .whitespacesAndNewlines)
        let translationService: Result<any SubtitleTranslationProviding, Error>
        do {
            translationService = .success(try await resolveTranslationService(provider: selectedTranslationProvider,
                platformKey: platformKey, settings: translationSettings))
        } catch {
            translationService = .failure(error)
        }
        let originalLines: [SubtitleLine]
        let readable = try await VaultManager.shared.readableURL(for: videoURL)
        defer { Task { @MainActor in VaultManager.shared.releaseReadableURL(readable) } }
        let pipeline: ProgressiveTranslationPipeline?
        if case .success(let service) = translationService {
            pipeline = ProgressiveTranslationPipeline(service: service, source: sourceLanguage, target: targetLanguage, progress: onEvent) { [cacheStore] lines, completed, total in
                let document = SubtitleDocument(sourceLanguage: sourceLanguage.rawValue, targetLanguage: targetLanguage,
                    engine: selectedEngine, model: expectedModel, translationProvider: selectedTranslationProvider,
                    translationConfiguration: translationSettings.cacheIdentity, isComplete: total > 0 && completed.count == total,
                    translationComplete: false, gptEnhanced: false, completedChunkIndexes: completed,
                    chunkDuration: LocalWhisperSubtitleService.chunkDuration, videoURL: videoURL, lines: lines)
                _ = try? Self.persist(document, for: videoURL, store: cacheStore, permit: cachePermit)
                await onPartialResult?(lines)
            }
        } else { pipeline = nil }
        do {
        if let reusableOriginalLines {
            originalLines = reusableOriginalLines
            onProgress?("已复用上次离线转写结果，正在重试翻译...")
        } else {
            switch selectedEngine {
            case .localWhisperKit:
                originalLines = try await localService.transcribeProgressively(
                    audioURL: readable,
                    sourceLanguage: sourceLanguage,
                    model: selectedModel,
                    preferredStartTime: preferredStartTime,
                    existingLines: initialLines,
                    completedChunkIndexes: Set(resumableDocument?.completedChunkIndexes ?? []),
                    onProgress: onProgress,
                    onEvent: onEvent,
                    onPartialResult: { [cacheStore] update in
                        await onTranscriptionProgress?(update.completedChunkIndexes.count, update.totalChunkCount)
                        if let pipeline { return await pipeline.submit(update.lines, completed: update.completedChunkIndexes, total: update.totalChunkCount) }
                        if !update.lines.isEmpty {
                            await onPartialResult?(update.lines)
                        }
                        guard !update.completedChunkIndexes.isEmpty else { return update.lines }
                        let partialDocument = SubtitleDocument(
                            sourceLanguage: sourceLanguage.rawValue,
                            targetLanguage: targetLanguage,
                            engine: selectedEngine,
                            model: expectedModel,
                            translationProvider: selectedTranslationProvider,
                            translationConfiguration: translationSettings.cacheIdentity,
                            isComplete: false,
                            translationComplete: false,
                            gptEnhanced: false,
                            completedChunkIndexes: update.completedChunkIndexes,
                            chunkDuration: LocalWhisperSubtitleService.chunkDuration,
                            videoURL: videoURL,
                            lines: update.lines
                        )
                        _ = try? Self.persist(partialDocument, for: videoURL, store: cacheStore, permit: cachePermit)
                        return update.lines
                    }
                )
            case .cloudOpenAI:
                guard platformKey.hasPrefix("sk-") else {
                    throw NSError(
                        domain: "AISubtitleError",
                        code: -10,
                        userInfo: [NSLocalizedDescriptionKey: "云端转写需要在设置中填写 OpenAI Platform API Key"]
                    )
                }
                onProgress?("正在提取“\(sourceLanguage.displayName)”音轨...")
                let tempAudioURL = FileManager.default.temporaryDirectory
                    .appendingPathComponent("lovort-audio-\(UUID().uuidString).m4a")
                defer { try? FileManager.default.removeItem(at: tempAudioURL) }
                try await extractAudioTrack(
                    from: readable,
                    outputAudioURL: tempAudioURL,
                    sourceLanguage: sourceLanguage
                )
                onEvent?(.phase(.transcribing))
                originalLines = try await CloudAISubtitleService(apiKey: platformKey).transcribe(
                    audioURL: tempAudioURL,
                    sourceLanguage: sourceLanguage,
                    onProgress: onProgress,
                    onPartialResult: { lines, completed, total in
                        await onTranscriptionProgress?(completed, total)
                        if let pipeline { _ = await pipeline.submit(lines, completed: Array(0..<completed), total: total) }
                        else { await onPartialResult?(lines) }
                    }
                )
            case .cloudAntigravity:
                throw NSError(
                    domain: "AISubtitleError",
                    code: -11,
                    userInfo: [NSLocalizedDescriptionKey: "Antigravity 字幕接口尚未配置，请选择离线 WhisperKit 或 OpenAI API"]
                )
            }
        }

        guard !originalLines.isEmpty else {
            throw NSError(
                domain: "AISubtitleError",
                code: -12,
                userInfo: [NSLocalizedDescriptionKey: "没有检测到有效台词，请确认视频包含清晰人声并选择正确音轨语言"]
            )
        }
        try Task.checkCancellation()

        var finalLines = originalLines
        var translationWarning: String?
        var translationComplete = false
        var gptEnhanced = false
        do {
            if let pipeline {
                _ = await pipeline.submit(originalLines, completed: [0], total: 1)
                let result = await withTaskCancellationHandler { await pipeline.finish() } onCancel: { Task { await pipeline.cancelAndDrain() } }
                try Task.checkCancellation()
                finalLines = result.lines
                translationWarning = result.warning.map { "翻译未完成：\($0)；已保留原文与成功译文" }
                translationComplete = finalLines.allSatisfy { !($0.translatedText ?? "").isEmpty }
            } else {
                _ = try translationService.get()
            }
            gptEnhanced = selectedTranslationProvider == .openAI && translationComplete
            if shouldEnhanceWithGPT, selectedTranslationProvider != .openAI, translationComplete {
                guard platformKey.hasPrefix("sk-") else {
                    throw NSError(
                        domain: "AISubtitleError",
                        code: -14,
                        userInfo: [NSLocalizedDescriptionKey: "GPT 语境精修需要 OpenAI Platform API Key"]
                    )
                }
                finalLines = try await CloudAISubtitleService(apiKey: platformKey).polish(
                    lines: finalLines,
                    targetLanguage: targetLanguage,
                    onProgress: onProgress
                )
                gptEnhanced = true
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            translationWarning = "翻译未完成：\(error.localizedDescription)；已保留原文与成功译文"
        }

        try Task.checkCancellation()
        let document = SubtitleDocument(
            sourceLanguage: sourceLanguage.rawValue,
            targetLanguage: targetLanguage,
            engine: selectedEngine,
            model: expectedModel,
            translationProvider: selectedTranslationProvider,
            translationConfiguration: translationSettings.cacheIdentity,
            isComplete: true,
            translationComplete: translationComplete,
            gptEnhanced: gptEnhanced,
            videoURL: videoURL,
            lines: finalLines
        )
        _ = try Self.persist(document, for: videoURL, store: cacheStore, permit: cachePermit)
        try Task.checkCancellation()
        let saveSidecars = {
            self.saveSRTBestEffort(lines: originalLines, videoURL: videoURL, suffix: "source")
            self.saveSRTBestEffort(lines: finalLines, videoURL: videoURL, suffix: "bilingual")
            self.saveSRTBestEffort(lines: finalLines, videoURL: videoURL, suffix: nil)
            if translationComplete {
                let translatedOnly = finalLines.map { line in
                    SubtitleLine(id: line.id, startTime: line.startTime, endTime: line.endTime,
                                 originalText: line.translatedText ?? line.originalText)
                }
                self.saveSRTBestEffort(lines: translatedOnly, videoURL: videoURL, suffix: "zh-Hans")
            }
        }
        if let cachePermit { try cachePermit.perform(saveSidecars) } else { try Task.checkCancellation(); saveSidecars() }

        if let translationWarning {
            onProgress?("⚠️ \(translationWarning)")
        } else {
            onProgress?("✅ 已生成并保存双语字幕（共 \(finalLines.count) 句）")
        }
        return finalLines
        } catch {
            if let pipeline { await pipeline.cancelAndDrain() }
            throw error
        }
    }

    /// Tries a short passage without creating a long-running task or writing subtitle cache.
    public func previewLocalVideo(
        videoURL: URL,
        startTime: TimeInterval,
        sourceLanguage: SubtitleSourceLanguage,
        model: OfflineWhisperModel,
        translationProvider: SubtitleTranslationProviderType,
        targetLanguage: String,
        onProgress: (@Sendable (String) -> Void)? = nil
    ) async throws -> SubtitlePreviewResult {
        let startedAt = Date()
        let readable = try await VaultManager.shared.readableURL(for: videoURL)
        defer { Task { @MainActor in VaultManager.shared.releaseReadableURL(readable) } }
        guard await OfflineWhisperModelManager.shared.installedFolder(for: model) != nil else {
            throw NSError(domain: "SubtitlePreview", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "请先在设置中安装所选离线模型"])
        }
        let hasActiveTask = await MainActor.run { SubtitleTaskManager.shared.activeTask != nil }
        guard !hasActiveTask else {
            throw NSError(domain: "SubtitlePreview", code: -2,
                          userInfo: [NSLocalizedDescriptionKey: "请等待当前字幕任务结束后再试预览"])
        }

        let asset = AVURLAsset(url: readable)
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        guard !tracks.isEmpty else {
            throw NSError(domain: "SubtitlePreview", code: -3,
                          userInfo: [NSLocalizedDescriptionKey: "视频没有可用音轨"])
        }
        let duration = CMTimeGetSeconds(try await asset.load(.duration))
        guard duration.isFinite, duration > 0 else {
            throw NSError(domain: "SubtitlePreview", code: -4,
                          userInfo: [NSLocalizedDescriptionKey: "无法读取视频时长"])
        }
        let halfWindow: TimeInterval = 15
        let primaryBegin = min(max(0, startTime - halfWindow), max(0, duration - 30))
        var candidateBegins: [TimeInterval] = [primaryBegin]
        if primaryBegin > 0 {
            candidateBegins.append(0)
        }

        let orderedTracks = AudioTrackSelection.orderedTracks(tracks, sourceLanguage: sourceLanguage)
        var sourceLines: [SubtitleLine]?
        var matchedTrackDescription: String?
        var resolvedBegin: TimeInterval = primaryBegin
        var resolvedLength: TimeInterval = min(30, duration - primaryBegin)

        windowLoop: for candidateBegin in candidateBegins {
            let length = min(30, duration - candidateBegin)
            for (attempt, track) in orderedTracks.enumerated() {
                try Task.checkCancellation()
                let originalIndex = tracks.firstIndex(where: { $0 === track }) ?? attempt
                let description = AudioTrackSelection.displayName(for: track, at: originalIndex)
                if candidateBegin != primaryBegin {
                    onProgress?("首选区间未检测到台词，正在尝试片头 30 秒（\(description)）…")
                } else {
                    onProgress?("正在提取 30 秒预览音频（\(description)，第 \(attempt + 1)/\(orderedTracks.count) 条）…")
                }
                let clipURL = FileManager.default.temporaryDirectory
                    .appendingPathComponent("lovort-preview-\(UUID().uuidString).m4a")
                defer { try? FileManager.default.removeItem(at: clipURL) }
                do {
                    try await exportPreviewAudio(
                        track: track, start: candidateBegin, duration: length, outputURL: clipURL
                    )
                    onProgress?("正在设备端识别（宽松人声检测）…")
                    let lines = try await localService.transcribe(
                        audioURL: clipURL, sourceLanguage: sourceLanguage, model: model,
                        useRelaxedVoiceDetection: LocalWhisperSubtitleService.previewUsesRelaxedVoiceDetection,
                        onProgress: onProgress
                    ).map { line in
                        SubtitleLine(id: line.id, startTime: line.startTime + candidateBegin,
                                     endTime: line.endTime + candidateBegin, originalText: line.originalText)
                    }
                    if !lines.isEmpty {
                        sourceLines = lines
                        matchedTrackDescription = description
                        resolvedBegin = candidateBegin
                        resolvedLength = length
                        break windowLoop
                    }
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    guard isNoSpeechError(error) else { throw error }
                }
            }
        }
        guard let sourceLines, let matchedTrackDescription else {
            throw NSError(
                domain: "SubtitlePreview",
                code: -8,
                userInfo: [NSLocalizedDescriptionKey:
                    "已尝试 \(orderedTracks.count) 条音轨，仍未检测到清晰人声；请确认原声音频语言或改用高精度模型"]
            )
        }
        var resultLines = sourceLines
        var warning: String?
        do {
            let platformKey = getSavedOpenAIKey().trimmingCharacters(in: .whitespacesAndNewlines)
            let service = try await resolveTranslationService(provider: translationProvider, platformKey: platformKey)
            resultLines = try await service.translate(
                lines: sourceLines, sourceLanguage: sourceLanguage,
                targetLanguage: targetLanguage, onProgress: onProgress
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            warning = "翻译预览未完成：\(error.localizedDescription)"
        }
        try Task.checkCancellation()
        return SubtitlePreviewResult(startTime: resolvedBegin, endTime: resolvedBegin + resolvedLength,
                                     elapsedTime: Date().timeIntervalSince(startedAt),
                                     audioTrackDescription: matchedTrackDescription,
                                     lines: resultLines, translationWarning: warning)
    }

    private func exportPreviewAudio(
        track: AVAssetTrack,
        start: TimeInterval,
        duration: TimeInterval,
        outputURL: URL
    ) async throws {
        let trackRange = try await track.load(.timeRange)
        let trackStartSeconds = CMTimeGetSeconds(trackRange.start)
        let safeTrackStart = trackStartSeconds.isFinite ? max(0, trackStartSeconds) : 0
        let sliceStartCM = CMTime(seconds: safeTrackStart + start, preferredTimescale: 600)
        let requestedDurationCM = CMTime(seconds: duration, preferredTimescale: 600)
        let trackEndCM = CMTimeAdd(trackRange.start, trackRange.duration)
        let availableDurationCM = CMTimeSubtract(trackEndCM, sliceStartCM)
        let finalDurationCM = CMTimeMinimum(requestedDurationCM, availableDurationCM)
        guard finalDurationCM > .zero else {
            throw NSError(domain: "SubtitlePreview", code: -5,
                          userInfo: [NSLocalizedDescriptionKey: "预览音频范围超出有效音轨"])
        }
        let sliceTimeRange = CMTimeRange(start: sliceStartCM, duration: finalDurationCM)
        let composition = AVMutableComposition()
        guard let compositionTrack = composition.addMutableTrack(
            withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid
        ) else {
            throw NSError(domain: "SubtitlePreview", code: -5,
                          userInfo: [NSLocalizedDescriptionKey: "无法创建预览音轨"])
        }
        try compositionTrack.insertTimeRange(sliceTimeRange, of: track, at: .zero)
        guard let exporter = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetAppleM4A) else {
            throw NSError(domain: "SubtitlePreview", code: -6,
                          userInfo: [NSLocalizedDescriptionKey: "无法导出预览音频"])
        }
        try? FileManager.default.removeItem(at: outputURL)
        exporter.outputURL = outputURL
        exporter.outputFileType = .m4a
        await exporter.export()
        guard exporter.status == .completed else {
            throw exporter.error ?? NSError(domain: "SubtitlePreview", code: -7,
                                            userInfo: [NSLocalizedDescriptionKey: "预览音频导出失败"])
        }
    }

    private func isNoSpeechError(_ error: Error) -> Bool {
        let error = error as NSError
        return error.domain == "LocalWhisperError"
            && error.localizedDescription.contains("未检测到清晰人声")
    }

    public func effectiveTranslationProvider(_ provider: SubtitleTranslationProviderType) -> SubtitleTranslationProviderType {
        if TranslationAPISettings(provider: provider).usesAccessKeyCredentials {
            let credentials = VolcengineAccessCredentials.saved(for: provider)
            return TranslationAPISettings.effectiveProvider(provider, hasCredential: !credentials.isEmpty)
        }
        let key = provider == .openAI ? getSavedOpenAIKey() : TranslationCredentialStore.shared.value(for: provider)
        return TranslationAPISettings.effectiveProvider(provider, hasCredential: !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    private func resolveTranslationService(
        provider: SubtitleTranslationProviderType,
        platformKey: String,
        settings: TranslationAPISettings? = nil
    ) async throws -> any SubtitleTranslationProviding {
        let selectedProvider = settings?.provider ?? effectiveTranslationProvider(provider)
        let configuration = settings ?? TranslationAPISettings(provider: selectedProvider)
        switch selectedProvider {
        case .apple:
            return await AppleTranslationBridge.shared
        case .openAI:
            guard platformKey.hasPrefix("sk-") else {
                throw NSError(
                    domain: "AISubtitleError",
                    code: -13,
                    userInfo: [NSLocalizedDescriptionKey: "GPT 翻译需要 OpenAI Platform API Key；ChatGPT Plus/Pro 订阅不等同于 API 额度"]
                )
            }
            return OpenAITranslationProvider(token: platformKey)
        case .volcengineMachineTranslation:
            return VolcengineMachineTranslationProvider(credentials: .saved(for: .volcengineMachineTranslation))
        case .volcengine where configuration.authenticationMode == .accessKey:
            return VolcengineAccessKeyTranslationProvider(settings: configuration,
                credentials: VolcengineAccessCredentials.saved())
        case .zhipu, .volcengine, .customChat:
            return ChatCompletionTranslationProvider(settings: configuration,
                apiKey: TranslationCredentialStore.shared.value(for: provider))
        case .deepL, .google, .azure:
            let key = TranslationCredentialStore.shared.value(for: provider)
            let region = UserDefaults.standard.string(forKey: "LovortAzureTranslatorRegion") ?? ""
            return RESTTranslationProvider(provider: provider, apiKey: key, azureRegion: region)
        }
    }

    private func saveSRTBestEffort(lines: [SubtitleLine], videoURL: URL, suffix: String?) {
        // Private transcripts stay in protected Application Support, outside file sharing.
        if videoURL.pathExtension == "vault" || videoURL.path.contains("/.Vault/") { return }

        let content = SRTParser.generateSRT(from: lines)
        let base = videoURL.deletingPathExtension()
        let sidecarURL = suffix.map { base.appendingPathExtension("\($0).srt") }
            ?? base.appendingPathExtension("srt")
        if (try? content.write(to: sidecarURL, atomically: true, encoding: .utf8)) != nil { return }

        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let fileName = suffix.map { "\(base.lastPathComponent).\($0).srt" } ?? "\(base.lastPathComponent).srt"
        let fallbackURL = documents.appendingPathComponent(fileName)
        try? content.write(to: fallbackURL, atomically: true, encoding: .utf8)
    }
}
