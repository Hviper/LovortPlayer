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
            lines: [SubtitleLine(startTime: 2, endTime: 4, originalText: "行くぞ", translatedText: "出发吧")]
        )
        let store = SubtitleCacheStore()

        _ = try store.save(document, for: videoURL)
        let loaded = store.load(for: videoURL)

        XCTAssertEqual(loaded?.lines.first?.originalText, "行くぞ")
        XCTAssertEqual(loaded?.lines.first?.translatedText, "出发吧")
        XCTAssertEqual(loaded?.model, OfflineWhisperModel.balanced.rawValue)
    }
}
