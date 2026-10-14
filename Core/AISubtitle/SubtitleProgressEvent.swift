import Foundation

public enum SubtitleProgressEvent: Sendable {
    case phase(SubtitleTaskPhase)
    case transcription(completed: Int, total: Int)
    case translation(completed: Int, total: Int)
}

public actor ProgressiveTranslationPipeline {
    private let service: any SubtitleTranslationProviding
    private let source: SubtitleSourceLanguage
    private let target: String
    private let checkpoint: @Sendable ([SubtitleLine], [Int], Int) async -> Void
    private let progress: (@Sendable (SubtitleProgressEvent) -> Void)?
    private var lines: [SubtitleLine] = []
    private var completedChunks: [Int] = []
    private var totalChunks = 0
    private var queued: [SubtitleLine] = []
    private var seen: Set<UUID> = []
    private var translations: [UUID: String] = [:]
    private var worker: Task<Void, Never>?
    private var checkpointTask: Task<Void, Never>?
    private var stopped = false
    private var cancelled = false
    private var warning: String?

    public init(service: any SubtitleTranslationProviding, source: SubtitleSourceLanguage, target: String,
                progress: (@Sendable (SubtitleProgressEvent) -> Void)? = nil,
                checkpoint: @escaping @Sendable ([SubtitleLine], [Int], Int) async -> Void) {
        self.service = service; self.source = source; self.target = target; self.progress = progress; self.checkpoint = checkpoint
    }
    public func submit(_ raw: [SubtitleLine], completed: [Int], total: Int) async -> [SubtitleLine] {
        lines = raw
        completedChunks = completed
        totalChunks = total
        for line in raw {
            if let text = line.translatedText, !text.isEmpty { translations[line.id] = text }
            if translations[line.id] == nil, seen.insert(line.id).inserted { queued.append(line) }
        }
        if worker == nil, !queued.isEmpty, !stopped { worker = Task { await self.run() } }
        let snapshot = merged()
        await publish()
        return snapshot
    }
    private func merged() -> [SubtitleLine] {
        lines.map { SubtitleLine(id: $0.id, startTime: $0.startTime, endTime: $0.endTime, originalText: $0.originalText, translatedText: translations[$0.id] ?? $0.translatedText) }
    }
    private func publish() async {
        let previous = checkpointTask
        let snapshot = merged(), completed = completedChunks, total = totalChunks
        let callback = checkpoint
        let task = Task { if let previous { await previous.value }; guard !Task.isCancelled, await self.canPublish() else { return }; await callback(snapshot, completed, total) }
        checkpointTask = task
        await task.value
    }
    private func run() async {
        defer { worker = nil }
        while !queued.isEmpty, !Task.isCancelled, !stopped {
            // Small batches yield partial translations/checkpoints and bound request memory.
            let batch = Array(queued.prefix(16))
            queued.removeFirst(batch.count)
            do {
                let started = Date()
                let results = try await service.translate(lines: batch, sourceLanguage: source, targetLanguage: target, onProgress: nil)
                await SubtitlePerformanceLog.shared.record(stage: "字幕翻译批次", model: "", seconds: Date().timeIntervalSince(started))
                guard !Task.isCancelled else { return }
                guard results.count == batch.count, Set(results.map(\.id)) == Set(batch.map(\.id)), results.allSatisfy({ !($0.translatedText ?? "").isEmpty }) else {
                    throw NSError(domain: "TranslationPipeline", code: 1, userInfo: [NSLocalizedDescriptionKey: "翻译批次返回不完整，已保存前面的成功译文"])
                }
                for result in results { if let text = result.translatedText, !text.isEmpty { translations[result.id] = text } }
                progress?(.translation(completed: translations.count, total: lines.count))
                await publish()
            } catch is CancellationError { return }
            catch { warning = error.localizedDescription; stopped = true }
        }
    }
    public func finish() async -> (lines: [SubtitleLine], warning: String?) {
        if let worker { await worker.value }
        return (merged(), warning)
    }
    private func canPublish() -> Bool { !cancelled }
    public func cancelAndDrain() async {
        stopped = true; cancelled = true
        let pendingWorker = worker, pendingCheckpoint = checkpointTask
        pendingWorker?.cancel(); pendingCheckpoint?.cancel()
        if let pendingWorker { await pendingWorker.value }
        if let pendingCheckpoint { await pendingCheckpoint.value }
    }
}
