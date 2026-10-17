import Combine
import Foundation
import UserNotifications

public enum SubtitleTaskPhase: String, Codable, Sendable {
    case queued
    case waitingForModel
    case preparingAudio
    case transcribing
    case translating
    case sourceReady
    case completed
    case pausedByUser
    case pausedBySystem
    case failed
    case cancelled

    public var isActive: Bool {
        switch self {
        case .queued, .waitingForModel, .preparingAudio, .transcribing, .translating: return true
        default: return false
        }
    }

    public var displayName: String {
        switch self {
        case .queued: return "排队中"
        case .waitingForModel: return "准备离线模型"
        case .preparingAudio: return "分析音轨"
        case .transcribing: return "生成原文字幕"
        case .translating: return "翻译字幕"
        case .sourceReady: return "原文字幕已就绪"
        case .completed: return "双语字幕已就绪"
        case .pausedByUser: return "已暂停"
        case .pausedBySystem: return "系统暂停，等待恢复"
        case .failed: return "处理失败"
        case .cancelled: return "已取消"
        }
    }
}

public struct SubtitleTaskItem: Identifiable, Codable, Sendable {
    public let id: UUID
    public var videoURL: URL
    public var videoTitle: String
    public var phase: SubtitleTaskPhase
    public var statusText: String
    public var transcriptionProgress: Double
    public var translationProgress: Double
    public var completedChunks: Int
    public var totalChunks: Int
    public var translatedBatches: Int
    public var totalTranslationBatches: Int
    public var lineCount: Int
    public var sourceLanguage: SubtitleSourceLanguage
    public var targetLanguage: String
    public var engine: AISubtitleEngineType
    public var model: OfflineWhisperModel
    public var translationProvider: SubtitleTranslationProviderType
    public var openAIConfiguration: OpenAITranslationExecutionConfiguration? = nil
    public var enhanceWithGPT: Bool
    public var isPrivate: Bool?
    public var preferredStartTime: TimeInterval
    public let createdAt: Date
    public var updatedAt: Date
    public var completedAt: Date?
    public var errorMessage: String?
    public var mediaID: UUID? = nil

    public var overallProgress: Double {
        switch phase {
        case .completed: return 1
        case .sourceReady: return min(0.99, transcriptionProgress * 0.72 + translationProgress * 0.28)
        default: return min(0.99, transcriptionProgress * 0.72 + translationProgress * 0.28)
        }
    }

    public var requiresNetworkConnectivity: Bool {
        if engine == .lanMac { return true }
        if engine == .cloudOpenAI || engine == .cloudAntigravity { return true }
        if translationProvider != .apple { return true }
        if enhanceWithGPT { return true }
        return false
    }

    func matchesConfiguration(
        sourceLanguage: SubtitleSourceLanguage,
        targetLanguage: String,
        engine: AISubtitleEngineType,
        model: OfflineWhisperModel,
        translationProvider: SubtitleTranslationProviderType,
        openAIConfiguration: OpenAITranslationExecutionConfiguration? = nil,
        enhanceWithGPT: Bool
    ) -> Bool {
        self.sourceLanguage == sourceLanguage
            && self.targetLanguage == targetLanguage
            && self.engine == engine
            && self.model == model
            && self.translationProvider == translationProvider
            && self.openAIConfiguration == openAIConfiguration
            && self.enhanceWithGPT == enhanceWithGPT
    }
}

@MainActor
public final class SubtitleTaskManager: ObservableObject {
    public static let shared = SubtitleTaskManager()
    public static let backgroundTaskIdentifier = "com.hviper.lovortplayer.subtitle-processing"

    nonisolated public static func shouldSuspendForBackground(engine: AISubtitleEngineType) -> Bool {
        engine != .lanMac
    }

    nonisolated public static func requiresNetworkConnectivity(for tasks: [SubtitleTaskItem]) -> Bool {
        tasks.contains { $0.requiresNetworkConnectivity }
    }

    public var hasPendingWork: Bool {
        tasks.contains { $0.phase.isActive || $0.phase == .queued || $0.phase == .pausedBySystem }
    }

    public var requiresNetworkConnectivityForPendingWork: Bool {
        let pending = tasks.filter { $0.phase.isActive || $0.phase == .queued || $0.phase == .pausedBySystem }
        return Self.requiresNetworkConnectivity(for: pending)
    }

    public var onBackgroundRescheduleNeeded: (@MainActor () -> Void)?
    private var isSuspendedForBackground: Bool = false

    @Published public private(set) var tasks: [SubtitleTaskItem] = []
    @Published public private(set) var liveSubtitles: [String: [SubtitleLine]] = [:]

    private var workerTask: Task<Void, Never>?
    private var runningTaskID: UUID?
    private var runTokens: [UUID: UUID] = [:]
    private var runPermits: [UUID: SubtitleRunPermit] = [:]
    private let storeURL: URL

    private init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let directory = support.appendingPathComponent("SubtitleTasks", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        storeURL = directory.appendingPathComponent("tasks.json")
        loadTasks()
        resumeInterruptedTasks()
        pumpQueue()
    }

    public var activeTask: SubtitleTaskItem? {
        tasks.first(where: { $0.id == runningTaskID }) ?? tasks.first(where: { $0.phase.isActive })
    }

    public var activeTaskCount: Int {
        tasks.filter { $0.phase.isActive }.count
    }

    public func task(for videoURL: URL) -> SubtitleTaskItem? {
        let key = videoKey(videoURL)
        return tasks
            .filter { videoKey($0.videoURL) == key && $0.phase != .cancelled }
            .max(by: { $0.updatedAt < $1.updatedAt })
    }

    public func subtitles(for videoURL: URL) -> [SubtitleLine]? {
        if AISubtitleCoordinator.isPrivateVideo(url: videoURL), !VaultManager.shared.isUnlocked { return nil }
        if let live = liveSubtitles[videoKey(videoURL)], !live.isEmpty { return live }
        return AISubtitleCoordinator.shared.loadLocalSRTIfAvailable(for: videoURL)
    }

    @discardableResult
    public func enqueue(
        videoURL: URL,
        videoTitle: String,
        sourceLanguage: SubtitleSourceLanguage = .automatic,
        targetLanguage: String = "中文 (简体)",
        engine: AISubtitleEngineType = .localWhisperKit,
        model: OfflineWhisperModel? = nil,
        translationProvider: SubtitleTranslationProviderType? = nil,
        enhanceWithGPT: Bool? = nil,
        isPrivate: Bool = false,
        preferredStartTime: TimeInterval = 0,
        forceRegenerate: Bool = false
    ) -> UUID {
        let selectedModel = model ?? AISubtitleCoordinator.shared.offlineModel
        let selectedProvider = AISubtitleCoordinator.shared.effectiveTranslationProvider(translationProvider ?? AISubtitleCoordinator.shared.translationProvider)
        let selectedEnhancement = enhanceWithGPT ?? AISubtitleCoordinator.shared.isGPTEnhancementEnabled
        let openAIConfiguration = selectedProvider == .openAI || selectedEnhancement
            ? AISubtitleCoordinator.shared.currentOpenAIConfiguration()
            : nil
        if let index = tasks.firstIndex(where: {
            videoKey($0.videoURL) == videoKey(videoURL) && $0.phase.isActive
        }) {
            if !forceRegenerate,
               tasks[index].matchesConfiguration(
                   sourceLanguage: sourceLanguage,
                   targetLanguage: targetLanguage,
                   engine: engine,
                   model: selectedModel,
                   translationProvider: selectedProvider,
                   openAIConfiguration: openAIConfiguration,
                   enhanceWithGPT: selectedEnhancement
               ) {
                tasks[index].preferredStartTime = preferredStartTime
                tasks[index].updatedAt = Date()
                saveTasks()
                return tasks[index].id
            }
            cancel(tasks[index].id)
        }

        if !forceRegenerate,
           let existing = task(for: videoURL),
           existing.phase == .completed,
           existing.matchesConfiguration(
               sourceLanguage: sourceLanguage,
               targetLanguage: targetLanguage,
               engine: engine,
               model: selectedModel,
               translationProvider: selectedProvider,
               openAIConfiguration: openAIConfiguration,
               enhanceWithGPT: selectedEnhancement
           ),
           let cached = SubtitleCacheStore().load(for: videoURL),
           cached.translationConfiguration == TranslationAPISettings(provider: selectedProvider)
                .effectiveCacheIdentity(openAIConfiguration: openAIConfiguration,
                                        enhanceWithGPT: selectedEnhancement) {
            return existing.id
        }

        if !forceRegenerate,
           let existingIndex = tasks.firstIndex(where: {
               videoKey($0.videoURL) == videoKey(videoURL)
                   && [.pausedByUser, .pausedBySystem, .failed, .sourceReady, .cancelled].contains($0.phase)
                   && $0.matchesConfiguration(
                       sourceLanguage: sourceLanguage,
                       targetLanguage: targetLanguage,
                       engine: engine,
                       model: selectedModel,
                       translationProvider: selectedProvider,
                       openAIConfiguration: openAIConfiguration,
                       enhanceWithGPT: selectedEnhancement
                   )
           }) {
            tasks[existingIndex].phase = .queued
            tasks[existingIndex].statusText = "等待从已保存进度继续"
            tasks[existingIndex].translationProgress = 0
            tasks[existingIndex].translatedBatches = 0
            tasks[existingIndex].totalTranslationBatches = 0
            tasks[existingIndex].preferredStartTime = preferredStartTime
            tasks[existingIndex].errorMessage = nil
            tasks[existingIndex].updatedAt = Date()
            saveTasks()
            pumpQueue()
            return tasks[existingIndex].id
        }

        let isPrivateVideo = AISubtitleCoordinator.isPrivateVideo(url: videoURL, isExplicitlyPrivate: isPrivate)
        let item = SubtitleTaskItem(
            id: UUID(),
            videoURL: videoURL,
            videoTitle: isPrivateVideo ? "私密视频" : videoTitle,
            phase: .queued,
            statusText: "等待开始",
            transcriptionProgress: 0,
            translationProgress: 0,
            completedChunks: 0,
            totalChunks: 0,
            translatedBatches: 0,
            totalTranslationBatches: 0,
            lineCount: 0,
            sourceLanguage: sourceLanguage,
            targetLanguage: targetLanguage,
            engine: engine,
            model: selectedModel,
            translationProvider: selectedProvider,
            openAIConfiguration: openAIConfiguration,
            enhanceWithGPT: selectedEnhancement,
            isPrivate: isPrivateVideo,
            preferredStartTime: preferredStartTime,
            createdAt: Date(),
            updatedAt: Date(),
            completedAt: nil,
            errorMessage: nil,
            mediaID: MediaIdentityStore.shared.id(for: videoURL)
        )
        tasks.append(item)
        trimHistory()
        saveTasks()
        pumpQueue()
        return item.id
    }

    public func pause(_ id: UUID) {
        guard let index = index(of: id) else { return }
        tasks[index].phase = .pausedByUser
        tasks[index].statusText = "已暂停，进度已经保存"
        tasks[index].updatedAt = Date()
        saveTasks()
        if runningTaskID == id {
            runTokens[id] = nil
            runPermits[id]?.invalidate()
            workerTask?.cancel()
        }
    }

    public func resume(_ id: UUID) {
        guard let index = index(of: id) else { return }
        if requiresOpenAIConfiguration(tasks[index]),
           tasks[index].openAIConfiguration?.credentialFingerprint == nil {
            let configuration = AISubtitleCoordinator.shared.currentOpenAIConfiguration()
            guard configuration.credentialFingerprint != nil else {
                tasks[index].phase = .failed
                tasks[index].statusText = "请先登录 ChatGPT 订阅账户或填写 Platform API Key"
                tasks[index].errorMessage = "配置凭证后再点击重试，任务会绑定当前账户和模型"
                tasks[index].updatedAt = Date()
                saveTasks()
                return
            }
            tasks[index].openAIConfiguration = configuration
        }
        tasks[index].phase = .queued
        tasks[index].statusText = "等待继续处理"
        tasks[index].errorMessage = nil
        tasks[index].updatedAt = Date()
        saveTasks()
        pumpQueue()
    }

    public func cancel(_ id: UUID) {
        guard let index = index(of: id) else { return }
        tasks[index].phase = .cancelled
        tasks[index].statusText = "任务已取消；已完成分片仍可用于续做"
        tasks[index].updatedAt = Date()
        saveTasks()
        if runningTaskID == id {
            runTokens[id] = nil
            runPermits[id]?.invalidate()
            workerTask?.cancel()
        }
    }

    public func cancelTasks(for videoURL: URL) {
        let key = videoKey(videoURL)
        let matchingIDs = tasks.filter { videoKey($0.videoURL) == key && $0.phase.isActive }.map(\.id)
        for id in matchingIDs { cancel(id) }
    }

    public func pauseTasks(for videoURL: URL) {
        for task in tasks where task.videoURL == videoURL && task.phase.isActive { pause(task.id) }
        flushTasks()
    }

    public func relocateTasks(from source: URL, to destination: URL, isPrivate: Bool) {
        let identity = MediaIdentityStore.shared.id(for: source)
        for task in tasks where task.videoURL == source && task.phase.isActive { pause(task.id) }
        for index in tasks.indices where tasks[index].videoURL == source {
            tasks[index].videoURL = destination
            tasks[index].videoTitle = destination.lastPathComponent
            tasks[index].mediaID = identity
            tasks[index].isPrivate = isPrivate
        }
        flushTasks()
    }

    public func purgeTasks(for videoURL: URL) {
        cancelTasks(for: videoURL)
        let key = videoKey(videoURL)
        tasks.removeAll { videoKey($0.videoURL) == key }
        liveSubtitles.removeValue(forKey: key)
        saveTasks()
    }

    public func retry(_ id: UUID) {
        resume(id)
    }

    public func removeFinished(_ id: UUID) {
        guard let item = tasks.first(where: { $0.id == id }), !item.phase.isActive else { return }
        tasks.removeAll { $0.id == id }
        liveSubtitles.removeValue(forKey: videoKey(item.videoURL))
        saveTasks()
    }

    private func pumpQueue() {
        guard !isSuspendedForBackground else { return }
        guard workerTask == nil,
              let next = tasks
                .filter({ $0.phase == .queued })
                .sorted(by: { $0.createdAt < $1.createdAt })
                .first else { return }
        runningTaskID = next.id
        let runToken = UUID()
        runTokens[next.id] = runToken
        runPermits[next.id] = SubtitleRunPermit()
        workerTask = Task { [weak self] in
            guard let self else { return }
            await self.execute(next.id, runToken: runToken)
            self.runPermits.removeValue(forKey: next.id)?.invalidate()
            self.runTokens[next.id] = nil
            self.runningTaskID = nil
            self.workerTask = nil
            self.pumpQueue()
        }
    }

    private func execute(_ id: UUID, runToken: UUID) async {
        guard let snapshot = tasks.first(where: { $0.id == id }) else { return }
        update(id) { item in
            item.phase = snapshot.engine == .localWhisperKit ? .waitingForModel : .preparingAudio
            item.statusText = snapshot.engine == .localWhisperKit ? "正在准备离线模型…" : "正在准备提取音轨…"
            item.errorMessage = nil
        }

        do {
            let isPrivate = AISubtitleCoordinator.isPrivateVideo(url: snapshot.videoURL, isExplicitlyPrivate: snapshot.isPrivate)
            try AISubtitleCoordinator.validateEngineForVideo(engine: snapshot.engine, isPrivate: isPrivate)
            guard !requiresOpenAIConfiguration(snapshot)
                    || snapshot.openAIConfiguration?.credentialFingerprint != nil else {
                throw NSError(
                    domain: "SubtitleTaskConfiguration",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey:
                        "GPT 任务未绑定可用账户，请先登录 ChatGPT 或填写 Platform API Key，再点击重试"]
                )
            }
            let lines = try await AISubtitleCoordinator.shared.processVideo(
                videoURL: snapshot.videoURL,
                targetLanguage: snapshot.targetLanguage,
                sourceLanguage: snapshot.sourceLanguage,
                engine: snapshot.engine,
                model: snapshot.model,
                translationProvider: snapshot.translationProvider,
                enhanceWithGPT: snapshot.enhanceWithGPT,
                openAIConfiguration: snapshot.openAIConfiguration,
                preferredStartTime: snapshot.preferredStartTime,
                forceRegenerate: false,
                isPrivate: snapshot.isPrivate == true,
                macJobID: snapshot.engine == .lanMac ? snapshot.id : nil,
                onProgress: { [weak self] status in
                    Task { @MainActor in self?.applyStatus(status, to: id, runToken: runToken) }
                },
                onTranscriptionProgress: { [weak self] completed, total in
                    await self?.applyTranscriptionProgress(completed: completed, total: total, to: id, runToken: runToken)
                },
                onPartialResult: { [weak self] partialLines in
                    await self?.applyPartialLines(partialLines, to: id, runToken: runToken)
                },
                onEvent: { [weak self] event in
                    Task { @MainActor in self?.applyEvent(event, to: id, runToken: runToken) }
                },
                cachePermit: runPermits[id]
            )
            try Task.checkCancellation()
            guard runTokens[id] == runToken else { throw CancellationError() }
            liveSubtitles[videoKey(snapshot.videoURL)] = lines
            let translatedCount = lines.filter { !($0.translatedText ?? "").isEmpty }.count
            update(id) { item in
                item.transcriptionProgress = 1
                item.lineCount = lines.count
                item.completedAt = Date()
                if translatedCount == lines.count, !lines.isEmpty {
                    item.translationProgress = 1
                    item.phase = .completed
                    item.statusText = "双语字幕已生成，共 \(lines.count) 句"
                } else {
                    item.phase = .sourceReady
                    item.statusText = "原文字幕已生成；翻译尚未完成，可点击重试"
                    item.errorMessage = "翻译未完成，原文字幕已经安全保存"
                }
            }
            let completed = tasks.first(where: { $0.id == id })
            MediaLibraryManager.shared.showNotification(
                message: completed?.phase == .completed
                    ? "《\(snapshot.videoTitle)》双语字幕已生成"
                    : "《\(snapshot.videoTitle)》原文字幕已生成",
                videoURL: snapshot.videoURL
            )
            scheduleCompletionNotification(for: snapshot, bilingual: completed?.phase == .completed)
        } catch is CancellationError {
            if let current = tasks.first(where: { $0.id == id }),
               current.phase.isActive,
               current.phase != .queued {
                update(id) { item in
                    item.phase = .pausedBySystem
                    item.statusText = "任务已暂停，下次继续时从检查点恢复"
                }
            }
        } catch {
            update(id) { item in
                item.phase = .failed
                item.statusText = "处理失败，可从已保存进度重试"
                item.errorMessage = error.localizedDescription
            }
            MediaLibraryManager.shared.showNotification(message: "字幕生成失败：\(error.localizedDescription)", isError: true)
        }
    }

    private func applyTranscriptionProgress(completed: Int, total: Int, to id: UUID, runToken: UUID) {
        guard runningTaskID == id, runTokens[id] == runToken, tasks.first(where: { $0.id == id })?.phase.isActive == true else { return }
        update(id) { item in
            item.phase = .transcribing
            item.completedChunks = completed
            item.totalChunks = total
            item.transcriptionProgress = total > 0 ? Double(completed) / Double(total) : 0
            if completed > 0 {
                item.statusText = "正在生成双语字幕 · 已完成 \(completed)/\(total) 个分片"
            } else {
                item.statusText = "准备识别 · 共 \(total) 个分片"
            }
        }
    }

    private func applyPartialLines(_ lines: [SubtitleLine], to id: UUID, runToken: UUID) {
        guard runningTaskID == id, runTokens[id] == runToken, let item = tasks.first(where: { $0.id == id }), item.phase.isActive else { return }
        liveSubtitles[videoKey(item.videoURL)] = lines
        let translatedCount = lines.filter { !($0.translatedText ?? "").isEmpty }.count
        update(id) { value in
            value.lineCount = lines.count
            if !lines.isEmpty, translatedCount > 0 {
                let chunkRatio = value.totalChunks > 0 ? Double(value.completedChunks) / Double(value.totalChunks) : value.transcriptionProgress
                let translatedRatio = Double(translatedCount) / Double(lines.count)
                value.translationProgress = max(value.translationProgress, min(1.0, chunkRatio * translatedRatio))
            }
        }
    }

    private func applyStatus(_ status: String, to id: UUID, runToken: UUID) {
        guard runningTaskID == id, runTokens[id] == runToken, let index = index(of: id), tasks[index].phase.isActive else { return }
        tasks[index].statusText = status
    }

    private func applyEvent(_ event: SubtitleProgressEvent, to id: UUID, runToken: UUID) {
        guard runningTaskID == id, runTokens[id] == runToken, let index = index(of: id), tasks[index].phase.isActive else { return }
        switch event {
        case .phase(let phase): tasks[index].phase = phase
        case .transcription(let completed, let total):
            tasks[index].phase = .transcribing
            tasks[index].completedChunks = completed
            tasks[index].totalChunks = total
            tasks[index].transcriptionProgress = total > 0 ? Double(completed) / Double(total) : 0
        case .translation(let completed, let total):
            if tasks[index].transcriptionProgress >= 1 { tasks[index].phase = .translating }
            tasks[index].translatedBatches = completed
            tasks[index].totalTranslationBatches = total
            tasks[index].translationProgress = total > 0 ? min(tasks[index].transcriptionProgress, Double(completed) / Double(total)) : 0
        }
    }

    public func pausePrivateTasks() {
        for task in tasks where AISubtitleCoordinator.isPrivateVideo(url: task.videoURL, isExplicitlyPrivate: task.isPrivate) && task.phase.isActive {
            pause(task.id)
        }
        for task in tasks where AISubtitleCoordinator.isPrivateVideo(url: task.videoURL, isExplicitlyPrivate: task.isPrivate) {
            liveSubtitles[videoKey(task.videoURL)] = nil
        }
    }

    public func suspendForBackground() {
        isSuspendedForBackground = true
        // A Mac job is already durable on the Mac; keep the client free to reconnect later.
        let activeIDs = tasks.filter { $0.phase.isActive && Self.shouldSuspendForBackground(engine: $0.engine) }.map(\.id)
        for id in activeIDs {
            guard let index = index(of: id) else { continue }
            tasks[index].phase = .pausedBySystem
            tasks[index].statusText = tasks[index].engine == .lanMac
                ? "Mac 继续转写，返回 App 后领取结果"
                : "锁屏期间暂停，返回 App 后从检查点继续"
            tasks[index].updatedAt = Date()
            runTokens[id] = nil
            runPermits[id]?.invalidate()
        }
        if let runningTaskID,
           let running = tasks.first(where: { $0.id == runningTaskID }),
           Self.shouldSuspendForBackground(engine: running.engine) {
            workerTask?.cancel()
        }
        flushTasks()
    }

    /// Runs queued tasks while the system has granted a BGProcessingTask window.
    public func runForBackgroundProcessing() async {
        isSuspendedForBackground = false
        resumeAfterForeground()

        while !isSuspendedForBackground {
            if let worker = workerTask {
                await worker.value
            } else if tasks.contains(where: { $0.phase == .queued }) {
                pumpQueue()
                if let worker = workerTask {
                    await worker.value
                } else {
                    break
                }
            } else {
                break
            }
        }

        if hasPendingWork {
            onBackgroundRescheduleNeeded?()
        }
    }

    public func waitForCurrentTask() async {
        if let workerTask { await workerTask.value }
    }

    public func cancelForBackgroundExpiration() {
        isSuspendedForBackground = true
        // The Mac-side job is durable and may continue, but all phone-side work,
        // including LAN polling, must stop when iOS revokes the processing window.
        let activeIDs = tasks.filter(\.phase.isActive).map(\.id)
        for id in activeIDs {
            guard let index = index(of: id) else { continue }
            tasks[index].phase = .pausedBySystem
            tasks[index].statusText = tasks[index].engine == .lanMac
                ? "Mac 继续转写，系统下次唤醒或返回 App 后领取结果"
                : "后台处理时间已结束，将从检查点继续"
            tasks[index].updatedAt = Date()
            runTokens[id] = nil
            runPermits[id]?.invalidate()
        }
        workerTask?.cancel()
        flushTasks()
        if hasPendingWork {
            onBackgroundRescheduleNeeded?()
        }
    }

    public func resumeAfterForeground() {
        isSuspendedForBackground = false
        for index in tasks.indices where tasks[index].phase == .pausedBySystem {
            tasks[index].phase = .queued
            tasks[index].statusText = "正在从已保存进度继续"
            tasks[index].updatedAt = Date()
        }
        flushTasks()
        pumpQueue()
    }

    private func update(_ id: UUID, mutation: (inout SubtitleTaskItem) -> Void) {
        guard let index = index(of: id) else { return }
        mutation(&tasks[index])
        tasks[index].updatedAt = Date()
        saveTasks()
    }

    private func index(of id: UUID) -> Int? {
        tasks.firstIndex(where: { $0.id == id })
    }

    private func resumeInterruptedTasks() {
        for index in tasks.indices where tasks[index].phase.isActive || tasks[index].phase == .pausedBySystem {
            if requiresOpenAIConfiguration(tasks[index]),
               tasks[index].openAIConfiguration?.credentialFingerprint == nil {
                tasks[index].phase = .failed
                tasks[index].statusText = "配置已升级，请点击重试后使用当前 GPT 账户和模型"
                tasks[index].errorMessage = "为避免静默切换计费通道，旧任务需要您确认后继续"
                tasks[index].updatedAt = Date()
                continue
            }
            tasks[index].phase = .queued
            tasks[index].statusText = "正在从上次检查点恢复"
            tasks[index].updatedAt = Date()
        }
        saveTasks()
    }

    private func requiresOpenAIConfiguration(_ item: SubtitleTaskItem) -> Bool {
        item.translationProvider == .openAI || item.enhanceWithGPT
    }

    private func trimHistory() {
        let finished = tasks.filter { !$0.phase.isActive }.sorted { $0.updatedAt > $1.updatedAt }
        let keepFinished = Set(finished.prefix(40).map(\.id))
        tasks.removeAll { !$0.phase.isActive && !keepFinished.contains($0.id) }
    }

    private func videoKey(_ url: URL) -> String {
        MediaIdentityStore.shared.id(for: url).uuidString
    }

    private func loadTasks() {
        guard let data = try? Data(contentsOf: storeURL) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        tasks = (try? decoder.decode([SubtitleTaskItem].self, from: data)) ?? []
        tasks.removeAll { !FileManager.default.fileExists(atPath: $0.videoURL.path) }
        for index in tasks.indices { tasks[index].mediaID = MediaIdentityStore.shared.id(for: tasks[index].videoURL) }
    }

    private var persistTask: Task<Void, Never>?
    private func saveTasks() {
        persistTask?.cancel()
        persistTask = Task { try? await Task.sleep(for: .milliseconds(400)); guard !Task.isCancelled else { return }; flushTasks() }
    }
    public func flushTasks() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(tasks) else { return }
        try? data.write(to: storeURL, options: .atomic)
        #if os(iOS)
        try? FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: storeURL.path)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var protectedURL = storeURL
        try? protectedURL.setResourceValues(values)
        #endif
    }

    private func scheduleCompletionNotification(for item: SubtitleTaskItem, bilingual: Bool) {
        guard UserDefaults.standard.bool(forKey: "settings.subtitleCompletionNotifications") else { return }
        let content = UNMutableNotificationContent()
        content.title = bilingual ? "双语字幕已就绪" : "原文字幕已就绪"
        content.body = item.isPrivate == true ? "私密视频的字幕任务已经完成" : item.videoTitle
        content.sound = .default
        let request = UNNotificationRequest(identifier: "subtitle-\(item.id.uuidString)", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}
