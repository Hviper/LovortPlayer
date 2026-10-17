import XCTest
@testable import LovortPlayerCore

final class SubtitlePipelineTests: XCTestCase {
    func testMacSubtitlePollingRecoversAfterTransientTimeout() async throws {
        let attempts = LANMacRetryAttemptCounter()
        let service = LANMacSubtitleService(
            session: .shared,
            pollInterval: .zero,
            sleeper: { _ in }
        )

        let result: String = try await service.retryTransientNetworkOperation(onProgress: nil) {
            try await attempts.next()
        }

        XCTAssertEqual(result, "reconnected")
        let attemptCount = await attempts.count
        XCTAssertEqual(attemptCount, 2)
    }

    func testMacSubtitleAddressOnlyAcceptsLocalNetworkHosts() {
        let previous = LANMacSubtitleSettings.address
        defer { LANMacSubtitleSettings.address = previous }
        LANMacSubtitleSettings.address = "192.168.1.20:8765"
        XCTAssertEqual(try LANMacSubtitleSettings.baseURL().host, "192.168.1.20")
        LANMacSubtitleSettings.address = "https://example.com"
        XCTAssertThrowsError(try LANMacSubtitleSettings.baseURL())
        LANMacSubtitleSettings.address = "http://8.8.8.8:8765"
        XCTAssertThrowsError(try LANMacSubtitleSettings.baseURL())
    }

    func testFirstOfflineSliceOnlyExportsPreviewAudio() {
        XCTAssertEqual(LocalWhisperSubtitleService.firstSliceDuration(240), 20)
        XCTAssertEqual(LocalWhisperSubtitleService.firstSliceDuration(26), 20)
        XCTAssertEqual(LocalWhisperSubtitleService.firstSliceDuration(25), 25)
        XCTAssertEqual(LocalWhisperSubtitleService.firstSliceDuration(12), 12)
    }

    func testSubtitleTaskPhaseActivityClassification() {
        XCTAssertTrue(SubtitleTaskPhase.queued.isActive)
        XCTAssertTrue(SubtitleTaskPhase.transcribing.isActive)
        XCTAssertTrue(SubtitleTaskPhase.translating.isActive)
        XCTAssertFalse(SubtitleTaskPhase.completed.isActive)
        XCTAssertFalse(SubtitleTaskPhase.pausedByUser.isActive)
        XCTAssertFalse(SubtitleTaskPhase.failed.isActive)
    }

    func testMacTasksRemainEligibleWhileLocalTasksSuspendForBackground() {
        XCTAssertTrue(SubtitleTaskManager.shouldSuspendForBackground(engine: .localWhisperKit))
        XCTAssertFalse(SubtitleTaskManager.shouldSuspendForBackground(engine: .lanMac))
    }

    func testSubtitleTaskProgressWeightsTranscriptionAndTranslation() {
        let now = Date()
        let item = SubtitleTaskItem(
            id: UUID(),
            videoURL: URL(fileURLWithPath: "/tmp/movie.mp4"),
            videoTitle: "movie.mp4",
            phase: .translating,
            statusText: "翻译中",
            transcriptionProgress: 1,
            translationProgress: 0.5,
            completedChunks: 10,
            totalChunks: 10,
            translatedBatches: 2,
            totalTranslationBatches: 4,
            lineCount: 100,
            sourceLanguage: .japanese,
            targetLanguage: "中文 (简体)",
            engine: .localWhisperKit,
            model: .balanced,
            translationProvider: .apple,
            enhanceWithGPT: false,
            isPrivate: nil,
            preferredStartTime: 0,
            createdAt: now,
            updatedAt: now,
            completedAt: nil,
            errorMessage: nil
        )
        XCTAssertEqual(item.overallProgress, 0.86, accuracy: 0.0001)
        XCTAssertEqual(OfflineWhisperModel.highAccuracy.estimatedSizeBytes, 626 * 1_024 * 1_024)
    }

    func testTaskReuseRequiresEntireSubtitleConfigurationToMatch() {
        let now = Date()
        let item = SubtitleTaskItem(
            id: UUID(),
            videoURL: URL(fileURLWithPath: "/tmp/movie.mp4"),
            videoTitle: "movie.mp4",
            phase: .completed,
            statusText: "已完成",
            transcriptionProgress: 1,
            translationProgress: 1,
            completedChunks: 10,
            totalChunks: 10,
            translatedBatches: 4,
            totalTranslationBatches: 4,
            lineCount: 100,
            sourceLanguage: .japanese,
            targetLanguage: "中文 (简体)",
            engine: .localWhisperKit,
            model: .balanced,
            translationProvider: .apple,
            enhanceWithGPT: false,
            isPrivate: false,
            preferredStartTime: 0,
            createdAt: now,
            updatedAt: now,
            completedAt: now,
            errorMessage: nil
        )

        XCTAssertTrue(item.matchesConfiguration(
            sourceLanguage: .japanese,
            targetLanguage: "中文 (简体)",
            engine: .localWhisperKit,
            model: .balanced,
            translationProvider: .apple,
            enhanceWithGPT: false
        ))
        XCTAssertFalse(item.matchesConfiguration(
            sourceLanguage: .english,
            targetLanguage: "中文 (简体)",
            engine: .localWhisperKit,
            model: .balanced,
            translationProvider: .apple,
            enhanceWithGPT: false
        ))
        XCTAssertFalse(item.matchesConfiguration(
            sourceLanguage: .japanese,
            targetLanguage: "中文 (简体)",
            engine: .localWhisperKit,
            model: .balanced,
            translationProvider: .deepL,
            enhanceWithGPT: false
        ))
    }

    func testOfflineModelProgressUsesEstimatedBytesInsteadOfWhisperFileCounts() {
        let metrics = OfflineWhisperModelManager.downloadMetrics(fraction: 0.25, model: .balanced)

        XCTAssertEqual(metrics.fraction, 0.25)
        XCTAssertEqual(metrics.completedBytes, 60 * 1_024 * 1_024)
        XCTAssertEqual(metrics.totalBytes, 240 * 1_024 * 1_024)
    }

    func testOfflineModelFolderRecognitionSupportsWhisperKitPrefix() {
        XCTAssertTrue(OfflineWhisperModelManager.modelFolderName("base", matches: .compact))
        XCTAssertTrue(OfflineWhisperModelManager.modelFolderName("openai_whisper-base", matches: .compact))
        XCTAssertTrue(OfflineWhisperModelManager.modelFolderName(
            "openai_whisper-large-v3-v20240930_626MB",
            matches: .highAccuracy
        ))
        XCTAssertFalse(OfflineWhisperModelManager.modelFolderName("openai_whisper-small.en", matches: .balanced))
    }

    func testPartialOfflineModelDirectoryIsNotTreatedAsInstalled() {
        XCTAssertTrue(OfflineWhisperModelManager.containsRequiredModelComponents(fileNames: [
            "MelSpectrogram.mlmodelc",
            "AudioEncoder.mlmodelc",
            "TextDecoder.mlmodelc"
        ]))
        XCTAssertFalse(OfflineWhisperModelManager.containsRequiredModelComponents(fileNames: [
            "config.json",
            "MelSpectrogram.mlmodelc",
            "AudioEncoder.mlmodelc"
        ]))
    }

    func testLanguageMapping() {
        XCTAssertEqual(SubtitleSourceLanguage.japanese.whisperCode, "ja")
        XCTAssertEqual(SubtitleSourceLanguage.english.whisperCode, "en")
        XCTAssertEqual(SubtitleSourceLanguage.korean.whisperCode, "ko")
        XCTAssertNil(SubtitleSourceLanguage.automatic.whisperCode)
    }

    func testAudioTracksPutSelectedLanguageBeforeOtherTracks() {
        let order = AudioTrackSelection.orderedIndices(
            languageTags: ["eng", "", "jpn", "ja-JP"],
            sourceLanguage: .japanese
        )

        XCTAssertEqual(order, [2, 3, 0, 1])
    }

    func testAutomaticAudioTrackOrderIsStable() {
        let order = AudioTrackSelection.orderedIndices(
            languageTags: ["eng", "jpn", ""],
            sourceLanguage: .automatic
        )

        XCTAssertEqual(order, [0, 1, 2])
    }

    func testRelaxedPreviewDetectionCanBeSelectedWithoutChangingDefaultTranscription() {
        XCTAssertFalse(LocalWhisperSubtitleService.defaultUsesRelaxedVoiceDetection)
        XCTAssertTrue(LocalWhisperSubtitleService.previewUsesRelaxedVoiceDetection)
    }

    func testTranslationJSONIsReorderedByIndex() throws {
        let content = """
        ```json
        [{"index":1,"translation":"第二句"},{"index":0,"translation":"第一句"}]
        ```
        """

        let values = try CloudAISubtitleService.decodeTranslations(from: content, expectedCount: 2)

        XCTAssertEqual(values, ["第一句", "第二句"])
    }

    func testSubscriptionSSERequiresCompletedEvent() throws {
        let stream = """
        data: {"type":"response.output_text.delta","delta":"[{\\"index\\":0,"}

        data: {"type":"response.output_text.delta","delta":"\\"translation\\":\\"你好\\"}]"}

        data: {"type":"response.completed","response":{"output":[]}}

        data: [DONE]
        """

        let text = try CloudAISubtitleService.extractStreamingResponseText(from: Data(stream.utf8))

        XCTAssertEqual(text, "[{\"index\":0,\"translation\":\"你好\"}]")
    }

    func testBilingualCacheRoundTrip() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let videoURL = folder.appendingPathComponent("episode.mkv")
        let document = SubtitleDocument(
            sourceLanguage: "日语",
            targetLanguage: "中文 (简体)",
            engine: .localWhisperKit,
            model: OfflineWhisperModel.balanced.rawValue,
            translationProvider: .apple,
            translationComplete: true,
            lines: [SubtitleLine(startTime: 2, endTime: 4, originalText: "行くぞ", translatedText: "出发吧")]
        )
        let store = SubtitleCacheStore()

        _ = try store.save(document, for: videoURL)
        let loaded = store.load(for: videoURL)

        XCTAssertEqual(loaded?.lines.first?.originalText, "行くぞ")
        XCTAssertEqual(loaded?.lines.first?.translatedText, "出发吧")
        XCTAssertEqual(loaded?.model, OfflineWhisperModel.balanced.rawValue)
        XCTAssertEqual(loaded?.translationProvider, .apple)
        XCTAssertEqual(loaded?.translationComplete, true)
    }

    func testProgressiveCacheRoundTripPreservesCheckpoint() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let videoURL = folder.appendingPathComponent("episode.mp4")
        let document = SubtitleDocument(
            sourceLanguage: SubtitleSourceLanguage.japanese.rawValue,
            targetLanguage: "中文 (简体)",
            engine: .localWhisperKit,
            model: OfflineWhisperModel.highAccuracy.rawValue,
            translationProvider: .apple,
            isComplete: false,
            translationComplete: false,
            completedChunkIndexes: [1, 2],
            chunkDuration: LocalWhisperSubtitleService.chunkDuration,
            lines: [SubtitleLine(startTime: 240, endTime: 242, originalText: "続けよう")]
        )

        _ = try SubtitleCacheStore().save(document, for: videoURL)
        let loaded = SubtitleCacheStore().load(for: videoURL)

        XCTAssertEqual(loaded?.isComplete, false)
        XCTAssertEqual(loaded?.translationComplete, false)
        XCTAssertEqual(loaded?.completedChunkIndexes, [1, 2])
    }

    func testLANUploadSanitizesTraversalAndAllowsCompatibilityFormats() {
        XCTAssertEqual(LANUploadPolicy.sanitizedFileName("../../Season 1/episode.mkv"), "episode.mkv")
        XCTAssertEqual(LANUploadPolicy.sanitizedFileName("bad:name.webm"), "bad_name.webm")
        XCTAssertTrue(LANUploadPolicy.allowedExtensions.contains("m2ts"))
        XCTAssertFalse(LANUploadPolicy.allowedExtensions.contains("html"))
    }

    func testProgressiveTranscriptionStartsNearPlayheadAndSkipsCompletedChunks() {
        let order = LocalWhisperSubtitleService.chunkProcessingOrder(
            totalChunks: 6,
            preferredChunk: 3,
            completed: [2, 3]
        )

        XCTAssertEqual(order, [4, 1, 5, 0])
    }

    func testSourceReadyProgressDoesNotShowOneHundredPercent() {
        let now = Date()
        var item = SubtitleTaskItem(
            id: UUID(),
            videoURL: URL(fileURLWithPath: "/tmp/sample.mp4"),
            videoTitle: "sample.mp4",
            phase: .sourceReady,
            statusText: "原文字幕已生成；翻译尚未完成",
            transcriptionProgress: 1.0,
            translationProgress: 0.0,
            completedChunks: 10,
            totalChunks: 10,
            translatedBatches: 0,
            totalTranslationBatches: 5,
            lineCount: 100,
            sourceLanguage: .english,
            targetLanguage: "中文 (简体)",
            engine: .localWhisperKit,
            model: .balanced,
            translationProvider: .apple,
            enhanceWithGPT: false,
            isPrivate: false,
            preferredStartTime: 0,
            createdAt: now,
            updatedAt: now,
            completedAt: nil,
            errorMessage: nil
        )

        // When translation has not started, overallProgress is 72%
        XCTAssertEqual(item.overallProgress, 0.72, accuracy: 0.001)
        XCTAssertLessThan(item.overallProgress, 1.0)

        // When translation is partially completed
        item.translationProgress = 0.5
        XCTAssertEqual(item.overallProgress, 0.86, accuracy: 0.001)
        XCTAssertLessThan(item.overallProgress, 1.0)

        // Even if translationProgress approaches 1.0 while still in .sourceReady, it must be capped and not show 100%
        item.translationProgress = 1.0
        XCTAssertEqual(item.overallProgress, 0.99, accuracy: 0.001)
        XCTAssertLessThan(item.overallProgress, 1.0)

        // Only .completed phase shows 100%
        item.phase = .completed
        XCTAssertEqual(item.overallProgress, 1.0)
    }

    func testNetworkConnectivityPolicyForPendingWork() {
        let now = Date()
        func makeItem(
            engine: AISubtitleEngineType = .localWhisperKit,
            provider: SubtitleTranslationProviderType = .apple,
            enhance: Bool = false
        ) -> SubtitleTaskItem {
            SubtitleTaskItem(
                id: UUID(),
                videoURL: URL(fileURLWithPath: "/tmp/test.mp4"),
                videoTitle: "test.mp4",
                phase: .queued,
                statusText: "排队中",
                transcriptionProgress: 0,
                translationProgress: 0,
                completedChunks: 0,
                totalChunks: 10,
                translatedBatches: 0,
                totalTranslationBatches: 5,
                lineCount: 0,
                sourceLanguage: .japanese,
                targetLanguage: "中文 (简体)",
                engine: engine,
                model: .balanced,
                translationProvider: provider,
                enhanceWithGPT: enhance,
                isPrivate: false,
                preferredStartTime: 0,
                createdAt: now,
                updatedAt: now,
                completedAt: nil,
                errorMessage: nil
            )
        }

        // Purely local WhisperKit + Apple translation does not require network
        let localItem = makeItem(engine: .localWhisperKit, provider: .apple, enhance: false)
        XCTAssertFalse(localItem.requiresNetworkConnectivity)

        // LAN Mac requires network
        let lanItem = makeItem(engine: .lanMac, provider: .apple, enhance: false)
        XCTAssertTrue(lanItem.requiresNetworkConnectivity)

        // Cloud OpenAI requires network
        let cloudOpenAIItem = makeItem(engine: .cloudOpenAI, provider: .apple, enhance: false)
        XCTAssertTrue(cloudOpenAIItem.requiresNetworkConnectivity)

        // Cloud Antigravity requires network
        let cloudAntigravityItem = makeItem(engine: .cloudAntigravity, provider: .apple, enhance: false)
        XCTAssertTrue(cloudAntigravityItem.requiresNetworkConnectivity)

        // Non-Apple translation requires network
        let deepLItem = makeItem(engine: .localWhisperKit, provider: .deepL, enhance: false)
        XCTAssertTrue(deepLItem.requiresNetworkConnectivity)

        let openAIProviderItem = makeItem(engine: .localWhisperKit, provider: .openAI, enhance: false)
        XCTAssertTrue(openAIProviderItem.requiresNetworkConnectivity)

        // GPT enhancement requires network
        let gptEnhancedItem = makeItem(engine: .localWhisperKit, provider: .apple, enhance: true)
        XCTAssertTrue(gptEnhancedItem.requiresNetworkConnectivity)

        // Aggregated collection checks
        XCTAssertFalse(SubtitleTaskManager.requiresNetworkConnectivity(for: []))
        XCTAssertFalse(SubtitleTaskManager.requiresNetworkConnectivity(for: [localItem]))
        XCTAssertTrue(SubtitleTaskManager.requiresNetworkConnectivity(for: [localItem, lanItem]))
        XCTAssertTrue(SubtitleTaskManager.requiresNetworkConnectivity(for: [localItem, deepLItem]))
        XCTAssertTrue(SubtitleTaskManager.requiresNetworkConnectivity(for: [localItem, gptEnhancedItem]))
    }

    func testPrivateVideoOnlyAllowsLocalWhisperKit() {
        // Non-private video allows all engines
        XCTAssertNoThrow(try AISubtitleCoordinator.validateEngineForVideo(engine: .localWhisperKit, isPrivate: false))
        XCTAssertNoThrow(try AISubtitleCoordinator.validateEngineForVideo(engine: .lanMac, isPrivate: false))
        XCTAssertNoThrow(try AISubtitleCoordinator.validateEngineForVideo(engine: .cloudOpenAI, isPrivate: false))
        XCTAssertNoThrow(try AISubtitleCoordinator.validateEngineForVideo(engine: .cloudAntigravity, isPrivate: false))

        // Private video ONLY allows local WhisperKit
        XCTAssertNoThrow(try AISubtitleCoordinator.validateEngineForVideo(engine: .localWhisperKit, isPrivate: true))

        // LAN Mac is rejected for private video
        XCTAssertThrowsError(try AISubtitleCoordinator.validateEngineForVideo(engine: .lanMac, isPrivate: true)) { error in
            let nsError = error as NSError
            XCTAssertTrue(nsError.localizedDescription.contains("Mac"))
        }

        // Cloud OpenAI is rejected for private video
        XCTAssertThrowsError(try AISubtitleCoordinator.validateEngineForVideo(engine: .cloudOpenAI, isPrivate: true)) { error in
            let nsError = error as NSError
            XCTAssertTrue(nsError.localizedDescription.contains("云端"))
        }

        // Cloud Antigravity is rejected for private video
        XCTAssertThrowsError(try AISubtitleCoordinator.validateEngineForVideo(engine: .cloudAntigravity, isPrivate: true)) { error in
            let nsError = error as NSError
            XCTAssertTrue(nsError.localizedDescription.contains("云端"))
        }

        // Private video identification helper
        XCTAssertTrue(AISubtitleCoordinator.isPrivateVideo(url: URL(fileURLWithPath: "/media/vault.mp4"), isExplicitlyPrivate: true))
        XCTAssertTrue(AISubtitleCoordinator.isPrivateVideo(url: URL(fileURLWithPath: "/media/video.vault"), isExplicitlyPrivate: false))
        XCTAssertTrue(AISubtitleCoordinator.isPrivateVideo(url: URL(fileURLWithPath: "/app/Documents/.Vault/clip.mp4"), isExplicitlyPrivate: false))
        XCTAssertFalse(AISubtitleCoordinator.isPrivateVideo(url: URL(fileURLWithPath: "/media/normal.mp4"), isExplicitlyPrivate: false))
    }

    @MainActor
    func testVaultReadableFileCleanupRemovesTrackedFilesAndDirectory() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("LovortPlayerVaultCleanup-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let readableFile = directory.appendingPathComponent("decrypted-video.mp4")
        try Data("sensitive".utf8).write(to: readableFile)

        VaultManager.removeReadableFiles([readableFile], directory: directory)

        XCTAssertFalse(FileManager.default.fileExists(atPath: readableFile.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
    }
}

private actor LANMacRetryAttemptCounter {
    private(set) var count = 0

    func next() throws -> String {
        count += 1
        if count == 1 { throw URLError(.timedOut) }
        return "reconnected"
    }
}
