import AVFoundation
import Foundation

/// 从音视频文件（MP4、MOV 等）中自动提取内嵌字幕轨道（如 tx3g、3GPP Timed Text、WebVTT）
public enum EmbeddedSubtitleExtractor {
    /// 异步提取视频中的内嵌字幕轨道
    public static func extract(from url: URL) async -> [SubtitleLine]? {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }

        let asset = AVURLAsset(url: url)
        let subtitleTracks = (try? await asset.loadTracks(withMediaType: .subtitle)) ?? []
        let textTracks = (try? await asset.loadTracks(withMediaType: .text)) ?? []
        let allTracks = subtitleTracks + textTracks
        guard !allTracks.isEmpty else { return nil }

        for track in allTracks {
            if let lines = await extractLines(from: track, in: asset), !lines.isEmpty {
                return lines
            }
        }
        return nil
    }

    private static func extractLines(from track: AVAssetTrack, in asset: AVAsset) async -> [SubtitleLine]? {
        do {
            let reader = try AVAssetReader(asset: asset)
            let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
            output.alwaysCopiesSampleData = false
            guard reader.canAdd(output) else { return nil }
            reader.add(output)
            guard reader.startReading() else { return nil }

            var lines: [SubtitleLine] = []
            while let sampleBuffer = output.copyNextSampleBuffer() {
                let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
                let dur = CMSampleBufferGetDuration(sampleBuffer)
                guard pts.isValid, pts.isNumeric, dur.isValid, dur.isNumeric else { continue }
                let startSeconds = pts.seconds
                let endSeconds = startSeconds + dur.seconds
                guard endSeconds > startSeconds else { continue }

                guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { continue }
                let length = CMBlockBufferGetDataLength(blockBuffer)
                guard length >= 2 else { continue }

                var buffer = [UInt8](repeating: 0, count: length)
                let status = CMBlockBufferCopyDataBytes(blockBuffer, atOffset: 0, dataLength: length, destination: &buffer)
                guard status == noErr else { continue }

                // tx3g（3GPP Timed Text）格式前两字节为大端序文本长度
                let textLength = Int(buffer[0]) << 8 | Int(buffer[1])
                guard textLength > 0, length >= 2 + textLength else { continue }

                let textData = Data(buffer[2 ..< 2 + textLength])
                guard let text = String(data: textData, encoding: .utf8) ?? String(data: textData, encoding: .utf16) else { continue }
                let cleanText = text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !cleanText.isEmpty else { continue }

                let subLines = cleanText.components(separatedBy: "\n")
                if subLines.count >= 2 {
                    let original = subLines[0]
                    let translated = subLines.dropFirst().joined(separator: "\n")
                    lines.append(SubtitleLine(startTime: startSeconds, endTime: endSeconds, originalText: original, translatedText: translated))
                } else {
                    lines.append(SubtitleLine(startTime: startSeconds, endTime: endSeconds, originalText: cleanText, translatedText: nil))
                }
            }
            return lines.isEmpty ? nil : lines
        } catch {
            return nil
        }
    }
}
