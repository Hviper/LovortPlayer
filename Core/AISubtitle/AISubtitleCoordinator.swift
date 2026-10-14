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
        offlineModel = OfflineWhisperModel(rawValue: modelValue) ?? .highAccuracy
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

        let candidates = sourceLanguage.trackLanguageCandidates
        let selectedTrack = tracks.first { track in
            let tag = (track.extendedLanguageTag ?? track.languageCode ?? "").lowercased()
            return candidates.contains { tag == $0 || tag.hasPrefix("\($0)-") }
        } ?? tracks.first!

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
        onPartialResult: (@Sendable ([SubtitleLine]) async -> Void)? = nil
    ) async throws -> [SubtitleLine] {
        let selectedEngine = engine ?? currentEngine
        let selectedModel = model ?? offlineModel
        let selectedTranslationProvider = translationProvider ?? self.translationProvider
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
            let keepTranslations = cachedDocument.translationProvider == selectedTranslationProvider
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
            let keepTranslations = resumableDocument.translationProvider == selectedTranslationProvider
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
        let streamingTranslationService = try? await resolveTranslationService(
            provider: selectedTranslationProvider,
            platformKey: platformKey
        )

        let originalLines: [SubtitleLine]
        if let reusableOriginalLines {
            originalLines = reusableOriginalLines
            onProgress?("已复用上次离线转写结果，正在重试翻译...")
        } else {
            switch selectedEngine {
            case .localWhisperKit:
                originalLines = try await localService.transcribe(
                    audioURL: videoURL,
                    sourceLanguage: sourceLanguage,
                    model: selectedModel,
                    preferredStartTime: preferredStartTime,
                    existingLines: initialLines,
                    completedChunkIndexes: Set(resumableDocument?.completedChunkIndexes ?? []),
                    onProgress: onProgress,
                    onPartialResult: { [cacheStore] update in
                        await onTranscriptionProgress?(update.completedChunkIndexes.count, update.totalChunkCount)
                        if !update.lines.isEmpty {
                            await onPartialResult?(update.lines)
                        }
                        guard !update.completedChunkIndexes.isEmpty else { return update.lines }
                        var mergedLines = update.lines
                        if let streamingTranslationService, !update.latestChunkLines.isEmpty {
                            onProgress?("正在流式翻译第 \(update.completedChunkIndexes.count)/\(update.totalChunkCount) 个字幕分片 (\(update.latestChunkLines.count) 句)...")
                            if let translatedChunk = try? await streamingTranslationService.translate(
                                lines: update.latestChunkLines,
                                sourceLanguage: sourceLanguage,
                                targetLanguage: targetLanguage,
                                onProgress: nil
                            ) {
                                let translatedByID = Dictionary(uniqueKeysWithValues: translatedChunk.map { ($0.id, $0) })
                                mergedLines = mergedLines.map { line in
                                    translatedByID[line.id] ?? line
                                }
                                await onPartialResult?(mergedLines)
                            }
                        }
                        let partialDocument = SubtitleDocument(
                            sourceLanguage: sourceLanguage.rawValue,
                            targetLanguage: targetLanguage,
                            engine: selectedEngine,
                            model: expectedModel,
                            translationProvider: selectedTranslationProvider,
                            isComplete: false,
                            translationComplete: false,
                            gptEnhanced: false,
                            completedChunkIndexes: update.completedChunkIndexes,
                            chunkDuration: LocalWhisperSubtitleService.chunkDuration,
                            videoURL: videoURL,
                            lines: mergedLines
                        )
                        _ = try? cacheStore.save(partialDocument, for: videoURL)
                        return mergedLines
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
                    from: videoURL,
                    outputAudioURL: tempAudioURL,
                    sourceLanguage: sourceLanguage
                )
                originalLines = try await CloudAISubtitleService(apiKey: platformKey).transcribe(
                    audioURL: tempAudioURL,
                    sourceLanguage: sourceLanguage,
                    onProgress: onProgress
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

        let originalDocument = SubtitleDocument(
            sourceLanguage: sourceLanguage.rawValue,
            targetLanguage: targetLanguage,
            engine: selectedEngine,
            model: expectedModel,
            translationProvider: selectedTranslationProvider,
            isComplete: true,
            translationComplete: false,
            gptEnhanced: false,
            videoURL: videoURL,
            lines: originalLines
        )
        _ = try cacheStore.save(originalDocument, for: videoURL)
        saveSRTBestEffort(lines: originalLines, videoURL: videoURL, suffix: "source")

        var finalLines = originalLines
        var translationWarning: String?
        var translationComplete = false
        var gptEnhanced = false
        do {
            let service = try await resolveTranslationService(
                provider: selectedTranslationProvider,
                platformKey: platformKey
            )
            let untranslatedLines = finalLines.filter { ($0.translatedText ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            if !untranslatedLines.isEmpty {
                let translated = try await service.translate(
                    lines: untranslatedLines,
                    sourceLanguage: sourceLanguage,
                    targetLanguage: targetLanguage,
                    onProgress: onProgress
                )
                let translatedByID = Dictionary(uniqueKeysWithValues: translated.map { ($0.id, $0) })
                finalLines = finalLines.map { translatedByID[$0.id] ?? $0 }
            }
            translationComplete = true
            gptEnhanced = selectedTranslationProvider == .openAI

            if shouldEnhanceWithGPT, selectedTranslationProvider != .openAI {
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
            translationWarning = "翻译未完成：\(error.localizedDescription)；已保留原文字幕"
        }

        try Task.checkCancellation()
        let document = SubtitleDocument(
            sourceLanguage: sourceLanguage.rawValue,
            targetLanguage: targetLanguage,
            engine: selectedEngine,
            model: expectedModel,
            translationProvider: selectedTranslationProvider,
            isComplete: true,
            translationComplete: translationComplete,
            gptEnhanced: gptEnhanced,
            videoURL: videoURL,
            lines: finalLines
        )
        _ = try cacheStore.save(document, for: videoURL)
        try Task.checkCancellation()
        saveSRTBestEffort(lines: finalLines, videoURL: videoURL, suffix: "bilingual")
        saveSRTBestEffort(lines: finalLines, videoURL: videoURL, suffix: nil)
        if translationComplete {
            let translatedOnly = finalLines.map { line in
                SubtitleLine(
                    id: line.id,
                    startTime: line.startTime,
                    endTime: line.endTime,
                    originalText: line.translatedText ?? line.originalText
                )
            }
            saveSRTBestEffort(lines: translatedOnly, videoURL: videoURL, suffix: "zh-Hans")
        }

        if let translationWarning {
            onProgress?("⚠️ \(translationWarning)")
        } else {
            onProgress?("✅ 已生成并保存双语字幕（共 \(finalLines.count) 句）")
        }
        return finalLines
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
        guard await OfflineWhisperModelManager.shared.installedFolder(for: model) != nil else {
            throw NSError(domain: "SubtitlePreview", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "请先在设置中安装所选离线模型"])
        }
        let hasActiveTask = await MainActor.run { SubtitleTaskManager.shared.activeTask != nil }
        guard !hasActiveTask else {
            throw NSError(domain: "SubtitlePreview", code: -2,
                          userInfo: [NSLocalizedDescriptionKey: "请等待当前字幕任务结束后再试预览"])
        }

        let asset = AVURLAsset(url: videoURL)
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        guard let track = tracks.first(where: { track in
            let tag = (track.extendedLanguageTag ?? track.languageCode ?? "").lowercased()
            return sourceLanguage.trackLanguageCandidates.contains { tag == $0 || tag.hasPrefix("\($0)-") }
        }) ?? tracks.first else {
            throw NSError(domain: "SubtitlePreview", code: -3,
                          userInfo: [NSLocalizedDescriptionKey: "视频没有可用音轨"])
        }
        let duration = CMTimeGetSeconds(try await asset.load(.duration))
        guard duration.isFinite, duration > 0 else {
            throw NSError(domain: "SubtitlePreview", code: -4,
                          userInfo: [NSLocalizedDescriptionKey: "无法读取视频时长"])
        }
        let begin = min(max(0, startTime), max(0, duration - 30))
        let length = min(30, duration - begin)
        let composition = AVMutableComposition()
        guard let compositionTrack = composition.addMutableTrack(
            withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid
        ) else {
            throw NSError(domain: "SubtitlePreview", code: -5,
                          userInfo: [NSLocalizedDescriptionKey: "无法创建预览音轨"])
        }
        let trackRange = try await track.load(.timeRange)
        try compositionTrack.insertTimeRange(trackRange, of: track, at: .zero)
        guard let exporter = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetAppleM4A) else {
            throw NSError(domain: "SubtitlePreview", code: -6,
                          userInfo: [NSLocalizedDescriptionKey: "无法导出预览音频"])
        }
        let clipURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("lovort-preview-\(UUID().uuidString).m4a")
        defer { try? FileManager.default.removeItem(at: clipURL) }
        exporter.outputURL = clipURL
        exporter.outputFileType = .m4a
        exporter.timeRange = CMTimeRange(
            start: CMTime(seconds: begin, preferredTimescale: 600),
            duration: CMTime(seconds: length, preferredTimescale: 600)
        )
        onProgress?("正在提取 30 秒预览音频…")
        await exporter.export()
        guard exporter.status == .completed else {
            throw exporter.error ?? NSError(domain: "SubtitlePreview", code: -7,
                                            userInfo: [NSLocalizedDescriptionKey: "预览音频导出失败"])
        }
        try Task.checkCancellation()
        let sourceLines = try await localService.transcribe(
            audioURL: clipURL, sourceLanguage: sourceLanguage, model: model,
            onProgress: onProgress
        ).map { line in
            SubtitleLine(id: line.id, startTime: line.startTime + begin,
                         endTime: line.endTime + begin, originalText: line.originalText)
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
        return SubtitlePreviewResult(startTime: begin, endTime: begin + length,
                                     lines: resultLines, translationWarning: warning)
    }

    private func resolveTranslationService(
        provider: SubtitleTranslationProviderType,
        platformKey: String
    ) async throws -> any SubtitleTranslationProviding {
        switch provider {
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
        case .deepL, .google, .azure:
            let key = TranslationCredentialStore.shared.value(for: provider)
            let region = UserDefaults.standard.string(forKey: "LovortAzureTranslatorRegion") ?? ""
            return RESTTranslationProvider(provider: provider, apiKey: key, azureRegion: region)
        }
    }

    private func saveSRTBestEffort(lines: [SubtitleLine], videoURL: URL, suffix: String?) {
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
