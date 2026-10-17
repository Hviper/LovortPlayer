import AVFoundation
import Foundation

private final class SubtitleWriterBox: @unchecked Sendable {
    let writer: AVAssetWriter
    init(_ writer: AVAssetWriter) { self.writer = writer }
}

@MainActor
enum MP4SubtitleTrackWriter {
    /// AVAssetExportSession can silently omit subtitle tracks in MP4. Mux compressed
    /// audio/video samples directly with tx3g samples instead of relying on that exporter.
    static func mux(asset: AVAsset, cues: [SubtitleExportCue], size: CGSize, to url: URL, onProgress: (@MainActor @Sendable (Double) -> Void)? = nil) async throws {
        let reader = try AVAssetReader(asset: asset)
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        struct Stream { let output: AVAssetReaderTrackOutput; let input: AVAssetWriterInput }
        var streams: [Stream] = []
        for track in try await asset.load(.tracks) where track.mediaType == .video || track.mediaType == .audio {
            let descriptions = try await track.load(.formatDescriptions)
            guard let format = descriptions.first else { throw SubtitleVideoExportError.unsupportedVideo }
            let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
            output.alwaysCopiesSampleData = false
            let input = AVAssetWriterInput(mediaType: track.mediaType, outputSettings: nil, sourceFormatHint: format)
            if track.mediaType == .video { input.transform = try await track.load(.preferredTransform) }
            guard reader.canAdd(output), writer.canAdd(input) else { throw SubtitleVideoExportError.unsupportedVideo }
            reader.add(output)
            writer.add(input)
            streams.append(Stream(output: output, input: input))
        }
        let format = try formatDescription(size: size)
        let captions = AVAssetWriterInput(mediaType: .subtitle, outputSettings: nil, sourceFormatHint: format)
        captions.extendedLanguageTag = "zh-Hans"
        captions.marksOutputTrackAsEnabled = true
        if let videoStream = streams.first(where: { $0.input.mediaType == .video }) {
            captions.addTrackAssociation(withTrackOf: videoStream.input, type: "forc")
        }
        guard writer.canAdd(captions) else { throw SubtitleVideoExportError.unsupportedVideo }
        writer.add(captions)
        guard writer.startWriting(), reader.startReading() else {
            writer.cancelWriting()
            throw writer.error ?? reader.error ?? SubtitleVideoExportError.unsupportedVideo
        }
        writer.startSession(atSourceTime: .zero)
        var finished = Set<Int>()
        var cursor = 0
        var lastReported = 0.0
        do {
            while finished.count < streams.count || cursor < cues.count {
                try Task.checkCancellation()
                var advanced = false
                for (index, stream) in streams.enumerated() where !finished.contains(index) && stream.input.isReadyForMoreMediaData {
                    if let buffer = stream.output.copyNextSampleBuffer() {
                        guard stream.input.append(buffer) else { throw writer.error ?? SubtitleVideoExportError.failed("音视频写入失败") }
                        if stream.input.mediaType == .video {
                            let progress = min(0.99, max(0, CMSampleBufferGetPresentationTimeStamp(buffer).seconds * 1000 / Double(cues.last?.endMilliseconds ?? 1)))
                            if progress - lastReported >= 0.01 { lastReported = progress; onProgress?(progress) }
                        }
                    } else {
                        guard reader.status != .failed else { throw reader.error ?? SubtitleVideoExportError.failed("音视频读取失败") }
                        stream.input.markAsFinished()
                        finished.insert(index)
                    }
                    advanced = true
                }
                if cursor < cues.count, captions.isReadyForMoreMediaData {
                    guard captions.append(try sample(cues[cursor], format: format)) else {
                        throw writer.error ?? SubtitleVideoExportError.failed("字幕写入失败")
                    }
                    cursor += 1
                    if cursor == cues.count { captions.markAsFinished() }
                    advanced = true
                }
                guard writer.status == .writing else { throw writer.error ?? SubtitleVideoExportError.failed("MP4 写入中断") }
                // Yield even when buffers are ready so UI cancellation and progress remain responsive.
                if advanced { await Task.yield() } else { try await Task.sleep(for: .milliseconds(5)) }
            }
            let box = SubtitleWriterBox(writer)
            await withTaskCancellationHandler { await writer.finishWriting() } onCancel: { box.writer.cancelWriting() }
            try Task.checkCancellation()
            guard writer.status == .completed else { throw writer.error ?? SubtitleVideoExportError.failed("MP4 写入未完成") }
        } catch {
            reader.cancelReading()
            writer.cancelWriting()
            throw error
        }
    }

    /// Construct the standard tx3g sample description, including an ftab font record.
    /// Creating a bare CMFormatDescription lacks the sample-description data required by AVAssetWriter.
    private static func formatDescription(size: CGSize) throws -> CMFormatDescription {
        func u16(_ value: UInt16) -> Data { var n = value.bigEndian; return withUnsafeBytes(of: &n) { Data($0) } }
        func u32(_ value: UInt32) -> Data { var n = value.bigEndian; return withUnsafeBytes(of: &n) { Data($0) } }
        func atom(_ type: String, _ body: Data) -> Data { u32(UInt32(body.count + 8)) + Data(type.utf8) + body }
        let width = UInt16(max(1, min(16_000, size.width)))
        let height = UInt16(max(1, min(16_000, size.height)))
        let fontSize = UInt8(SubtitleLayout.exportFontSize(for: size))
        var data = Data(repeating: 0, count: 6) + u16(1) + u32(0) + Data([1, 255, 0, 0, 0, 0])
        // Bottom region; one centered subtitle track containing the chosen original/translated text.
        let inset = UInt16(min(Double(height) / 4, SubtitleLayout.bottomInset(for: size)))
        let margin = UInt16(Double(width) * (1 - SubtitleLayout.widthFraction(for: size)) / 2)
        data += u16(UInt16(Double(height) * 0.55)) + u16(margin) + u16(height - inset) + u16(width - margin)
        data += u16(0) + u16(0) + u16(1) + Data([0, fontSize, 255, 255, 255, 255])
        data += atom("ftab", u16(1) + u16(1) + Data([9]) + Data("Helvetica".utf8))
        data = atom("tx3g", data)
        var format: CMFormatDescription?
        let status = data.withUnsafeBytes { raw in
            CMTextFormatDescriptionCreateFromBigEndianTextDescriptionData(
                allocator: kCFAllocatorDefault, bigEndianTextDescriptionData: raw.baseAddress!.assumingMemoryBound(to: UInt8.self),
                size: data.count, flavor: nil, mediaType: kCMMediaType_Subtitle, formatDescriptionOut: &format)
        }
        guard status == noErr, let format else { throw SubtitleVideoExportError.failed("字幕格式初始化失败（\(status)）") }
        return format
    }

    private static func sample(_ cue: SubtitleExportCue, format: CMFormatDescription) throws -> CMSampleBuffer {
        let data = try SubtitleExportTimeline.timedTextPayload(cue.text)
        var block: CMBlockBuffer?
        var status = CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil,
            blockLength: data.count, blockAllocator: kCFAllocatorDefault, customBlockSource: nil,
            offsetToData: 0, dataLength: data.count, flags: 0, blockBufferOut: &block)
        guard status == noErr, let block else { throw SubtitleVideoExportError.failed("字幕缓冲区初始化失败") }
        status = data.withUnsafeBytes { raw in
            CMBlockBufferReplaceDataBytes(with: raw.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: data.count)
        }
        guard status == noErr else { throw SubtitleVideoExportError.failed("字幕缓冲区写入失败") }
        var timing = CMSampleTimingInfo(duration: CMTime(value: cue.endMilliseconds - cue.startMilliseconds, timescale: 1000),
            presentationTimeStamp: CMTime(value: cue.startMilliseconds, timescale: 1000), decodeTimeStamp: .invalid)
        var size = data.count
        var sample: CMSampleBuffer?
        status = CMSampleBufferCreateReady(allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: format,
            sampleCount: 1, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
            sampleSizeEntryCount: 1, sampleSizeArray: &size, sampleBufferOut: &sample)
        guard status == noErr, let sample else { throw SubtitleVideoExportError.failed("字幕样本初始化失败") }
        return sample
    }
}
