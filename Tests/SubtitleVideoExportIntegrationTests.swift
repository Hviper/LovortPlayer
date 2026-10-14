import Foundation
import XCTest
import AVFoundation
@testable import LovortPlayerCore

final class SubtitleVideoExportIntegrationTests: XCTestCase {
    @MainActor
    func testBothModesPreserveVideoAndPortraitOrientation() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let exporter = SubtitleVideoExporter(cacheDirectory: root)
        for portrait in [false, true] {
            let source = root.appendingPathComponent(portrait ? "portrait.mp4" : "landscape.mp4")
            try await makeVideo(at: source, portrait: portrait)
            let before = try Data(contentsOf: source)
            for mode in SubtitleVideoExportMode.allCases {
                let output = try await exporter.export(videoURL: source, lines: [SubtitleLine(startTime: 0.5, endTime: 1.5, originalText: "Hello", translatedText: "你好")], mode: mode)
                let asset = AVURLAsset(url: output)
                let duration = try await asset.load(.duration).seconds
                XCTAssertTrue(abs(duration - 2) < 0.05)
                let videos = try await asset.loadTracks(withMediaType: .video)
                XCTAssertEqual(videos.count, 1)
                let size = try await videos[0].load(.naturalSize)
                let transform = try await videos[0].load(.preferredTransform)
                let oriented = CGRect(origin: .zero, size: size).applying(transform).standardized.size
                XCTAssertEqual(oriented, portrait ? CGSize(width: 180, height: 320) : CGSize(width: 320, height: 180))
                let captions = try await asset.loadTracks(withMediaType: .subtitle)
                XCTAssertEqual(captions.count, mode == .embedded ? 1 : 0)
                if mode == .embedded {
                    // AVAssetReader does not expose tx3g samples on all OS versions.
                    // Verify the readable subtitle track and its UTF-8 payload in the MP4.
                    let bytes = try Data(contentsOf: output)
                    XCTAssertTrue(bytes.range(of: try SubtitleExportTimeline.timedTextPayload("Hello\n你好")) != nil)
                }
                exporter.retire(output)
            }
            XCTAssertEqual(try Data(contentsOf: source), before)
        }
    }

    @MainActor
    private func makeVideo(at url: URL, portrait: Bool) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 320, AVVideoHeightKey: 180])
        if portrait { input.transform = CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: 180, ty: 0) }
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB])
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? SubtitleVideoExportError.failed("test writer") }
        writer.startSession(atSourceTime: .zero)
        var buffer: CVPixelBuffer?
        guard CVPixelBufferCreate(kCFAllocatorDefault, 320, 180, kCVPixelFormatType_32ARGB, nil, &buffer) == kCVReturnSuccess, let buffer else {
            throw SubtitleVideoExportError.failed("test pixel buffer")
        }
        CVPixelBufferLockBaseAddress(buffer, [])
        let address = CVPixelBufferGetBaseAddress(buffer)!
        memset(address, 0x66, CVPixelBufferGetBytesPerRow(buffer) * 180)
        CVPixelBufferUnlockBaseAddress(buffer, [])
        for frame in 0..<20 {
            while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(5)) }
            guard adaptor.append(buffer, withPresentationTime: CMTime(value: Int64(frame), timescale: 10)) else {
                throw writer.error ?? SubtitleVideoExportError.failed("test frame")
            }
        }
        input.markAsFinished()
        writer.endSession(atSourceTime: CMTime(value: 2, timescale: 1))
        await writer.finishWriting()
        guard writer.status == .completed else { throw writer.error ?? SubtitleVideoExportError.failed("test finish") }
    }
}
