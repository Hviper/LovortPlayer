import XCTest
@testable import LovortMacSubtitleService

final class JobParsingTests: XCTestCase {

    func testDecodeQueuedJob() throws {
        let json = """
        {
            "id": "12345678-1234-1234-1234-123456789abc",
            "status": "queued",
            "language": "ja",
            "preferred_start": 0.0,
            "completed_chunks": [],
            "total_chunks": 0,
            "segments": [],
            "error": null,
            "updated_at": 1729000000.0
        }
        """.data(using: .utf8)!

        let job = try JSONDecoder().decode(TranscriptionJob.self, from: json)
        XCTAssertEqual(job.id, "12345678-1234-1234-1234-123456789abc")
        XCTAssertEqual(job.shortId, "12345678")
        XCTAssertEqual(job.status, .queued)
        XCTAssertEqual(job.language, "ja")
        XCTAssertEqual(job.completedChunks.count, 0)
        XCTAssertEqual(job.totalChunks, 0)
        XCTAssertEqual(job.progressPercentage, 0.0)
        XCTAssertEqual(job.segmentProgressDescription, "计算总切片中...")
        XCTAssertNil(job.error)
    }

    func testDecodeProcessingJob() throws {
        let json = """
        {
            "id": "87654321-4321-4321-4321-cba987654321",
            "status": "processing",
            "language": "en",
            "preferred_start": 240.0,
            "completed_chunks": [0, 1],
            "total_chunks": 5,
            "segments": [
                {"chunk": 0, "start": 0.0, "end": 2.5, "text": "Hello world"}
            ],
            "error": null,
            "updated_at": 1729000500.0
        }
        """.data(using: .utf8)!

        let job = try JSONDecoder().decode(TranscriptionJob.self, from: json)
        XCTAssertEqual(job.status, .processing)
        XCTAssertEqual(job.completedChunks, [0, 1])
        XCTAssertEqual(job.totalChunks, 5)
        XCTAssertEqual(job.progressPercentage, 0.4, accuracy: 0.001)
        XCTAssertEqual(job.progressPercentageText, "40%")
        XCTAssertEqual(job.segmentProgressDescription, "2 / 5 片段")
        XCTAssertEqual(job.segmentsCount, 1)
    }

    func testDecodeCompletedJob() throws {
        let json = """
        {
            "id": "abcdef01-0000-0000-0000-000000000000",
            "status": "completed",
            "language": null,
            "preferred_start": 0,
            "completed_chunks": [0, 1, 2],
            "total_chunks": 3,
            "segments": [
                {"chunk": 0, "start": 0.0, "end": 2.0, "text": "Part 1"},
                {"chunk": 1, "start": 240.0, "end": 242.0, "text": "Part 2"}
            ],
            "error": null,
            "updated_at": 1729001000.0
        }
        """.data(using: .utf8)!

        let job = try JSONDecoder().decode(TranscriptionJob.self, from: json)
        XCTAssertEqual(job.status, .completed)
        XCTAssertEqual(job.progressPercentage, 1.0)
        XCTAssertEqual(job.progressPercentageText, "100%")
        XCTAssertEqual(job.segmentProgressDescription, "3 / 3 片段")
        XCTAssertEqual(job.segmentsCount, 2)
    }

    func testDecodeFailedJobWithError() throws {
        let json = """
        {
            "id": "fail0000-0000-0000-0000-000000000000",
            "status": "failed",
            "completed_chunks": [],
            "total_chunks": 0,
            "error": "Uploaded audio is missing",
            "updated_at": 1729002000.0
        }
        """.data(using: .utf8)!

        let job = try JSONDecoder().decode(TranscriptionJob.self, from: json)
        XCTAssertEqual(job.status, .failed)
        XCTAssertEqual(job.error, "Uploaded audio is missing")
        XCTAssertEqual(job.segmentProgressDescription, "未开始即失败")
        XCTAssertEqual(job.progressPercentage, 0.0)
    }
}
