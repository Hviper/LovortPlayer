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
        onPartialResult: (@Sendable ([SubtitleLine]) async -> Void)? = nil
    ) async throws -> [SubtitleLine] {
        let selectedEngine = engine ?? currentEngine
        let selectedModel = model ?? offlineModel
        let selectedTranslationProvider = translationProvider ?? self.translationProvider
        let shouldEnhanceWithGPT = enhanceWithGPT ?? isGPTEnhancementEnabled
        currentEngine = selectedEngine
        offlineModel = selectedModel
        self.translationProvider = selectedTranslationProvider
        isGPTEnhancementEnabled = shouldEnhanceWithGPT

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
            return cachedDocument.lines.map {
                SubtitleLine(id: $0.id, startTime: $0.startTime, endTime: $0.endTime, originalText: $0.originalText)
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

        let platformKey = getSavedOpenAIKey().trimmingCharacters(in: .whitespacesAndNewlines)
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
                    existingLines: resumableDocument?.lines ?? [],
                    completedChunkIndexes: Set(resumableDocument?.completedChunkIndexes ?? []),
                    onProgress: onProgress,
                    onPartialResult: { [cacheStore] update in
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
                            lines: update.lines
                        )
                        _ = try? cacheStore.save(partialDocument, for: videoURL)
                        await onPartialResult?(update.lines)
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
        saveSRTBestEffort(lines: originalLines, videoURL: videoURL)

        var finalLines = originalLines
        var translationWarning: String?
        var translationComplete = false
        var gptEnhanced = false
        do {
            let service: any SubtitleTranslationProviding
            switch selectedTranslationProvider {
            case .apple:
                service = await AppleTranslationBridge.shared
            case .openAI:
                guard platformKey.hasPrefix("sk-") else { throw NSError(
                    domain: "AISubtitleError",
                    code: -13,
                    userInfo: [NSLocalizedDescriptionKey: "GPT 翻译需要 OpenAI Platform API Key；ChatGPT Plus/Pro 订阅不等同于 API 额度"]
                ) }
                service = OpenAITranslationProvider(token: platformKey)
            case .deepL, .google, .azure:
                let key = TranslationCredentialStore.shared.value(for: selectedTranslationProvider)
                let region = UserDefaults.standard.string(forKey: "LovortAzureTranslatorRegion") ?? ""
                service = RESTTranslationProvider(provider: selectedTranslationProvider, apiKey: key, azureRegion: region)
            }
            finalLines = try await service.translate(
                lines: originalLines,
                sourceLanguage: sourceLanguage,
                targetLanguage: targetLanguage,
                onProgress: onProgress
            )
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
        } catch {
            translationWarning = "翻译未完成：\(error.localizedDescription)；已保留原文字幕"
        }

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
        saveSRTBestEffort(lines: finalLines, videoURL: videoURL)

        if let translationWarning {
            onProgress?("⚠️ \(translationWarning)")
        } else {
            onProgress?("✅ 已生成并保存双语字幕（共 \(finalLines.count) 句）")
        }
        return finalLines
    }

    private func saveSRTBestEffort(lines: [SubtitleLine], videoURL: URL) {
        let content = SRTParser.generateSRT(from: lines)
        let sidecarURL = videoURL.deletingPathExtension().appendingPathExtension("srt")
        if (try? content.write(to: sidecarURL, atomically: true, encoding: .utf8)) != nil { return }

        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let fallbackURL = documents
            .appendingPathComponent(videoURL.deletingPathExtension().lastPathComponent)
            .appendingPathExtension("srt")
        try? content.write(to: fallbackURL, atomically: true, encoding: .utf8)
    }
}
