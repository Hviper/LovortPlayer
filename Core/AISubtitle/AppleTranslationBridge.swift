import Combine
import Foundation
@preconcurrency import Translation
import OSLog

@MainActor
public final class AppleTranslationBridge: ObservableObject, SubtitleTranslationProviding {
    public static let shared = AppleTranslationBridge()

    @Published public var configuration: TranslationSession.Configuration?

    private struct PendingRequest {
        let id: UUID
        let lines: [SubtitleLine]
        let onProgress: (@Sendable (String) -> Void)?
        let continuation: CheckedContinuation<[SubtitleLine], Error>
    }

    private var pending: PendingRequest?
    private var executingRequestID: UUID?
    private var timeoutTask: Task<Void, Never>?
    private let logger = Logger(subsystem: "com.hviper.lovortplayer", category: "AppleTranslation")

    private let sessionStartTimeout: Int

    init(sessionStartTimeout: Int = 30) {
        self.sessionStartTimeout = sessionStartTimeout
    }

    public func translate(
        lines: [SubtitleLine],
        sourceLanguage: SubtitleSourceLanguage,
        targetLanguage: String,
        onProgress: (@Sendable (String) -> Void)?
    ) async throws -> [SubtitleLine] {
        try Task.checkCancellation()
        guard pending == nil else { throw bridgeError("Apple 翻译正在处理另一批字幕") }
        guard !lines.isEmpty else { return [] }
        onProgress?("正在准备 Apple 设备端翻译（首次使用可能需要下载语言包）...")

        let source = sourceLanguage.appleLanguage
        let target = targetLanguage.appleTargetLanguage
        let requestID = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                pending = PendingRequest(id: requestID, lines: lines, onProgress: onProgress, continuation: continuation)
                let next = TranslationSession.Configuration(source: source, target: target)
                if configuration?.source == source, configuration?.target == target, configuration != nil {
                    configuration?.invalidate()
                } else {
                    configuration = next
                }
                logger.info("Queued Apple translation: \(lines.count) lines")
                scheduleTimeout(seconds: sessionStartTimeout, requestID: requestID,
                    message: "Apple 翻译会话未启动，请保持应用在前台后重试")
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.cancel(requestID)
            }
        }
    }

    public func perform(using session: TranslationSession) async {
        guard let pending, executingRequestID == nil else { return }
        let requestID = pending.id
        executingRequestID = requestID
        let started = ContinuousClock.now
        logger.info("Apple translation session started")
        do {
            pending.onProgress?("正在准备 Apple 翻译语言包，请在系统提示中确认下载...")
            scheduleTimeout(seconds: 600, requestID: requestID,
                message: "Apple 翻译语言包准备超时，请确认下载并保持应用在前台")
            // prepareTranslation cannot identify a nil source without sample text.
            let needsLanguageDetection = session.sourceLanguage == nil
            if !needsLanguageDetection {
                try await session.prepareTranslation()
            }
            guard self.pending?.id == requestID else { return }
            logger.info("Apple language preparation completed in \(String(describing: started.duration(to: .now)))")
            var translations: [Int: String] = [:]
            let batchSize = 40
            let batchCount = Int(ceil(Double(pending.lines.count) / Double(batchSize)))
            for batchIndex in 0..<batchCount {
                try Task.checkCancellation()
                guard self.pending?.id == requestID else { throw CancellationError() }
                pending.onProgress?("正在进行 Apple 设备端翻译 \(batchIndex + 1)/\(batchCount)...")
                let start = batchIndex * batchSize
                let end = min(start + batchSize, pending.lines.count)
                var requests: [TranslationSession.Request] = []
                for index in start..<end {
                    requests.append(TranslationSession.Request(
                        sourceText: pending.lines[index].originalText,
                        clientIdentifier: String(index)
                    ))
                }
                let detectsLanguage = needsLanguageDetection && batchIndex == 0
                scheduleTimeout(seconds: detectsLanguage ? 600 : 120, requestID: requestID,
                    message: detectsLanguage
                        ? "Apple 自动识别与语言包准备超时，原文字幕可继续使用"
                        : "Apple 翻译当前批次超时，原文字幕可继续使用，稍后可重试")
                let batchStarted = ContinuousClock.now
                let responses = try await session.translations(from: requests)
                logger.info("Apple batch \(batchIndex + 1) completed in \(String(describing: batchStarted.duration(to: .now)))")
                guard self.pending?.id == requestID else { throw CancellationError() }
                for response in responses {
                    if let identifier = response.clientIdentifier, let index = Int(identifier) {
                        translations[index] = response.targetText
                    }
                }
            }
            guard translations.count == pending.lines.count else { throw bridgeError("Apple 翻译返回的字幕数量不完整") }
            let result = pending.lines.enumerated().map { index, line in
                SubtitleLine(
                    id: line.id,
                    startTime: line.startTime,
                    endTime: line.endTime,
                    originalText: line.originalText,
                    translatedText: translations[index]
                )
            }
            finish(.success(result), requestID: requestID)
        } catch {
            finish(.failure(error), requestID: requestID)
        }
    }

    private func cancel(_ requestID: UUID) {
        finish(.failure(CancellationError()), requestID: requestID)
    }

    private func finish(_ result: Result<[SubtitleLine], Error>, requestID: UUID? = nil) {
        guard let pending, requestID == nil || pending.id == requestID else { return }
        self.pending = nil
        executingRequestID = nil
        timeoutTask?.cancel()
        timeoutTask = nil
        // Keep the configuration so repeat requests can explicitly invalidate it.
        logger.info("Apple translation request finished")
        pending.continuation.resume(with: result)
    }

    private func scheduleTimeout(seconds: Int, requestID: UUID, message: String) {
        timeoutTask?.cancel()
        timeoutTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .seconds(seconds)) } catch { return }
            guard let self, self.pending?.id == requestID else { return }
            self.logger.error("Apple translation timed out: \(message, privacy: .public)")
            self.finish(.failure(self.bridgeError(message)), requestID: requestID)
        }
    }

    private func bridgeError(_ message: String) -> NSError {
        NSError(domain: "AppleTranslation", code: -1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}

private extension SubtitleSourceLanguage {
    var appleLanguage: Locale.Language? {
        guard let whisperCode else { return nil }
        return Locale.Language(identifier: whisperCode)
    }
}

private extension String {
    var appleTargetLanguage: Locale.Language {
        if contains("繁") { return Locale.Language(identifier: "zh-Hant") }
        if contains("英") { return Locale.Language(identifier: "en") }
        return Locale.Language(identifier: "zh-Hans")
    }
}
