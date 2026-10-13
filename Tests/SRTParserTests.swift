import XCTest
@testable import LovortPlayerCore

final class SRTParserTests: XCTestCase {
    func testParsesCRLFAndTimestampSettings() {
        let input = "\u{feff}1\r\n00:00:01,250 --> 00:00:03,500 position:50%\r\nHello world\r\n\r\n2\r\n00:00:04.000 --> 00:00:05.200\r\nSecond line\r\n"

        let lines = SRTParser.parse(srtString: input)

        XCTAssertEqual(lines.count, 2)
        XCTAssertEqual(lines[0].startTime, 1.25, accuracy: 0.001)
        XCTAssertEqual(lines[0].endTime, 3.5, accuracy: 0.001)
        XCTAssertEqual(lines[0].originalText, "Hello world")
        XCTAssertEqual(lines[1].startTime, 4, accuracy: 0.001)
    }

    func testRejectsMalformedOrZeroLengthEntries() {
        let input = """
        1
        invalid --> 00:00:03,000
        Bad

        2
        00:00:04,000 --> 00:00:04,000
        Zero
        """

        XCTAssertTrue(SRTParser.parse(srtString: input).isEmpty)
    }

    func testGeneratesBilingualSRT() {
        let lines = [SubtitleLine(
            startTime: 1.2,
            endTime: 3.4,
            originalText: "こんにちは",
            translatedText: "你好"
        )]

        let value = SRTParser.generateSRT(from: lines)

        XCTAssertTrue(value.contains("00:00:01,200 --> 00:00:03,400"))
        XCTAssertTrue(value.contains("こんにちは\n你好"))
    }
}
