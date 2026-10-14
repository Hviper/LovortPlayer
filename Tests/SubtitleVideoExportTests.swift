import Foundation
import XCTest
import AVFoundation
import CoreImage
@testable import LovortPlayerCore

final class SubtitleVideoExportTests: XCTestCase {
    func testTimelineClearsGapsCombinesOverlapAndClampsToVideo() throws {
        let lines = [SubtitleLine(startTime: 1, endTime: 2, originalText: "A", translatedText: "甲"),
                     SubtitleLine(startTime: 1.5, endTime: 3, originalText: "B"),
                     SubtitleLine(startTime: -2, endTime: 0.5, originalText: "Start"),
                     SubtitleLine(startTime: .nan, endTime: 4, originalText: "Invalid")]
        let cues = try SubtitleExportTimeline.make(lines: lines, duration: 4.0001, textMode: .bilingual)
        XCTAssertEqual(cues.map(\.text), ["Start", "", "A\n甲", "A\n甲\nB", "B", ""])
        XCTAssertEqual(cues.first?.startMilliseconds, 0)
        XCTAssertEqual(cues.last?.endMilliseconds, 4001)
        for index in 1..<cues.count { XCTAssertEqual(cues[index-1].endMilliseconds, cues[index].startMilliseconds) }
    }

    func testMissingTranslationFallsBackAndUTF8ByteLengthIsCorrect() throws {
        XCTAssertEqual(SubtitleExportTextMode.translated.text(for: SubtitleLine(startTime: 0, endTime: 1, originalText: "原文")), "原文")
        let payload = try SubtitleExportTimeline.timedTextPayload("你好")
        XCTAssertEqual(Array(payload.prefix(2)), [0, 6])
        XCTAssertEqual(String(data: payload.dropFirst(2), encoding: .utf8), "你好")
        XCTAssertThrowsError(try SubtitleExportTimeline.timedTextPayload(String(repeating: "中", count: 22_000)))
        XCTAssertThrowsError(try SubtitleExportTimeline.make(lines: [], duration: 1, textMode: .original))
        XCTAssertThrowsError(try SubtitleExportTimeline.make(lines: [], duration: .infinity, textMode: .original))
    }

    func testBurnInChangesCaptionFramesButLeavesGapsUntouched() throws {
        let cues = try SubtitleExportTimeline.make(lines: [SubtitleLine(startTime: 1, endTime: 2, originalText: "Hello", translatedText: "你好")], duration: 3, textMode: .bilingual)
        let renderer = SubtitleBurnInRenderer(cues: cues)
        let source = CIImage(color: CIColor(red: 0, green: 0, blue: 1)).cropped(to: CGRect(x: 0, y: 0, width: 320, height: 180))
        let context = CIContext(options: [.useSoftwareRenderer: true])
        func pixels(_ image: CIImage) -> Data {
            var bytes = Data(count: 320 * 180 * 4)
            bytes.withUnsafeMutableBytes { context.render(image, toBitmap: $0.baseAddress!, rowBytes: 320 * 4, bounds: source.extent, format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB()) }
            return bytes
        }
        XCTAssertEqual(pixels(try renderer.image(at: 0.5, over: source)), pixels(source))
        XCTAssertNotEqual(pixels(try renderer.image(at: 1.5, over: source)), pixels(source))
        XCTAssertEqual(pixels(try renderer.image(at: 2, over: source)), pixels(source))
    }

    func testPortraitPlaybackAnchorsToVideoInsteadOfScreenBottom() {
        let viewport = CGRect(x: 0, y: 0, width: 390, height: 844)
        let video = SubtitleLayout.videoFrame(size: CGSize(width: 1920, height: 1080), in: viewport)
        let safe = CGRect(x: 0, y: 47, width: 390, height: 763)
        let hidden = SubtitleLayout.playbackRegion(video: video, safeBounds: safe, controlsHeight: 0)
        let controls = SubtitleLayout.playbackRegion(video: video, safeBounds: safe, controlsHeight: 128)
        XCTAssertTrue(hidden.maxY < 540)
        XCTAssertTrue(hidden.minY >= video.minY)
        XCTAssertEqual(hidden, controls) // The controls below the letterboxed picture need no lift.
        XCTAssertTrue(hidden.minX >= safe.minX && hidden.maxX <= safe.maxX)
    }

    func testLandscapePlaybackAvoidsControlsAndScreenEdges() {
        let viewport = CGRect(x: 0, y: 0, width: 844, height: 390)
        let video = SubtitleLayout.videoFrame(size: CGSize(width: 1920, height: 1080), in: viewport)
        let safe = CGRect(x: 47, y: 0, width: 750, height: 369)
        let hidden = SubtitleLayout.playbackRegion(video: video, safeBounds: safe, controlsHeight: 0)
        let controls = SubtitleLayout.playbackRegion(video: video, safeBounds: safe, controlsHeight: 128)
        XCTAssertTrue(controls.maxY <= safe.maxY - 128 - 12)
        XCTAssertTrue(controls.maxY < hidden.maxY)
        XCTAssertTrue(controls.minX >= safe.minX && controls.maxX <= safe.maxX)
        let portrait = SubtitleLayout.videoFrame(size: CGSize(width: 1080, height: 1920), in: viewport)
        let portraitCaption = SubtitleLayout.playbackRegion(video: portrait, safeBounds: safe, controlsHeight: 0)
        XCTAssertTrue(portraitCaption.minX >= portrait.minX && portraitCaption.maxX <= portrait.maxX)
    }

    func testExportFontUsesShortEdgeForBothOrientations() {
        XCTAssertEqual(SubtitleLayout.exportFontSize(for: CGSize(width: 1920, height: 1080)),
                       SubtitleLayout.exportFontSize(for: CGSize(width: 1080, height: 1920)))
        XCTAssertTrue(SubtitleLayout.widthFraction(for: CGSize(width: 1080, height: 1920)) < SubtitleLayout.widthFraction(for: CGSize(width: 1920, height: 1080)))
    }

    @MainActor
    func testOutputLeaseAndOwnedDirectoryCleanup() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("SubtitleVideoExports").appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let output = directory.appendingPathComponent("video.mp4")
        try Data([1]).write(to: output)
        let exporter = SubtitleVideoExporter(cacheDirectory: root)
        exporter.retain(output)
        exporter.retire(output)
        XCTAssertTrue(FileManager.default.fileExists(atPath: output.path))
        exporter.release(output)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
        let source = root.appendingPathComponent("source.mp4")
        try Data([2]).write(to: source)
        exporter.retire(source)
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
    }
}
