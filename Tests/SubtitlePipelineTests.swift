import XCTest
@testable import LovortPlayerCore

final class SubtitlePipelineTests: XCTestCase {
    func testLanguageMapping() {
        XCTAssertEqual(SubtitleSourceLanguage.japanese.whisperCode, "ja")
        XCTAssertEqual(SubtitleSourceLanguage.english.whisperCode, "en")
        XCTAssertEqual(SubtitleSourceLanguage.korean.whisperCode, "ko")
        XCTAssertNil(SubtitleSourceLanguage.automatic.whisperCode)
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
}
