import XCTest
import Foundation
@testable import LovortPlayerCore

private actor PipelineTestService: SubtitleTranslationProviding {
    var calls = 0
    let failAt: Int?
    init(failAt: Int? = nil) { self.failAt = failAt }
    func translate(lines: [SubtitleLine], sourceLanguage: SubtitleSourceLanguage, targetLanguage: String, onProgress: (@Sendable (String) -> Void)?) async throws -> [SubtitleLine] {
        calls += 1
        if calls == failAt { throw NSError(domain: "Test", code: 1) }
        return lines.map { SubtitleLine(id: $0.id, startTime: $0.startTime, endTime: $0.endTime, originalText: $0.originalText, translatedText: "译文：" + $0.originalText) }
    }
}
private actor PipelineCheckpoints {
    var saved: [[SubtitleLine]] = []
    func record(_ lines: [SubtitleLine]) { saved.append(lines) }
}
final class ProgressiveTranslationTests: XCTestCase {
    func testFirstChunkTranslatesBeforeLaterChunksAndIsNotRepeated() async {
        let service = PipelineTestService(), store = PipelineCheckpoints()
        let pipeline = ProgressiveTranslationPipeline(service: service, source: .english, target: "中文") { lines, _, _ in await store.record(lines) }
        let first = SubtitleLine(startTime: 0, endTime: 1, originalText: "first")
        _ = await pipeline.submit([first], completed: [], total: 30)
        let early = await pipeline.finish()
        XCTAssertEqual(early.lines[0].translatedText, "译文：first")
        let countBeforeSecondChunk = await service.calls
        XCTAssertEqual(countBeforeSecondChunk, 1)
        let second = SubtitleLine(startTime: 1, endTime: 2, originalText: "second")
        _ = await pipeline.submit([first, second], completed: [0], total: 30)
        let final = await pipeline.finish()
        XCTAssertEqual(final.lines.count, 2)
        XCTAssertTrue(final.lines.allSatisfy { $0.translatedText != nil })
        let count = await service.calls
        XCTAssertEqual(count, 2)
        let checkpoints = await store.saved
        XCTAssertTrue(checkpoints.contains { $0.count == 1 && $0[0].translatedText != nil })
    }
    func testSuccessfulBatchesSurviveFailureAndRetryOnlyMissingTranslations() async {
        let service = PipelineTestService(failAt: 2), store = PipelineCheckpoints()
        let raw = (0..<35).map { SubtitleLine(startTime: Double($0), endTime: Double($0 + 1), originalText: "line \($0)") }
        let pipeline = ProgressiveTranslationPipeline(service: service, source: .english, target: "中文") { lines, _, _ in await store.record(lines) }
        _ = await pipeline.submit(raw, completed: [0], total: 1)
        let failed = await pipeline.finish()
        XCTAssertNotNil(failed.warning)
        XCTAssertEqual(failed.lines.filter { $0.translatedText != nil }.count, 16)
        let retryService = PipelineTestService()
        let retry = ProgressiveTranslationPipeline(service: retryService, source: .english, target: "中文") { _, _, _ in }
        _ = await retry.submit(failed.lines, completed: [0], total: 1)
        let recovered = await retry.finish()
        XCTAssertTrue(recovered.lines.allSatisfy { $0.translatedText != nil })
        let retryCount = await retryService.calls
        XCTAssertEqual(retryCount, 2) // 19 missing lines, not all 35.
    }
}
