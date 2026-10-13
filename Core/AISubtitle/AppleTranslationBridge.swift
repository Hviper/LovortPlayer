import Combine
import Foundation
import Translation

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

    private init() {}

    public func translate(
        lines: [SubtitleLine],
        sourceLanguage: SubtitleSourceLanguage,
        targetLanguage: String,
        onProgress: (@Sendable (String) -> Void)?
    ) async throws -> [SubtitleLine] {
        guard pending == nil else { throw bridgeError("Apple 翻译正在处理另一批字幕") }
        guard !lines.isEmpty else { return [] }
        onProgress?("正在准备 Apple 设备端翻译（首次使用可能需要下载语言包）...")

        let source = sourceLanguage.appleLanguage
        let target = targetLanguage.appleTargetLanguage
        let requestID = UUID()
        return try await withCheckedThrowingContinuation { continuation in
            pending = PendingRequest(id: requestID, lines: lines, onProgress: onProgress, continuation: continuation)
            configuration = TranslationSession.Configuration(source: source, target: target)
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(600))
                guard let self, self.pending?.id == requestID else { return }
                self.finish(.failure(self.bridgeError("Apple 翻译等待超时，请确认语言包下载已经完成")))
            }
        }
    }

    public func perform(using session: TranslationSession) async {
        guard let pending else { return }
        do {
            var translations: [Int: String] = [:]
            let batchSize = 100
            let batchCount = Int(ceil(Double(pending.lines.count) / Double(batchSize)))
            for batchIndex in 0..<batchCount {
                try Task.checkCancellation()
                pending.onProgress?("正在进行 Apple 设备端翻译 \(batchIndex + 1)/\(batchCount)...")
                let start = batchIndex * batchSize
                let end = min(start + batchSize, pending.lines.count)
                let requests = (start..<end).map { index in
                    TranslationSession.Request(
                        sourceText: pending.lines[index].originalText,
                        clientIdentifier: String(index)
                    )
                }
                let responses = try await session.translations(from: requests)
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
            finish(.success(result))
        } catch {
            finish(.failure(error))
        }
    }

    private func finish(_ result: Result<[SubtitleLine], Error>) {
        guard let pending else { return }
        self.pending = nil
        configuration = nil
        pending.continuation.resume(with: result)
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
