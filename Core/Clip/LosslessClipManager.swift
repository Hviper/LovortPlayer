import Foundation
import AVFoundation

public final class LosslessClipManager: @unchecked Sendable {
    public static let shared = LosslessClipManager()

    private init() {}

    /// 无损精准截取视频（使用 Passthrough GOP 复制码流，不经过重编码）
    public func exportLosslessClip(
        assetURL: URL,
        outputURL: URL,
        startTime: CMTime,
        endTime: CMTime
    ) async throws {
        let asset = AVURLAsset(url: assetURL)
        guard let exportSession = AVAssetExportSession(
            asset: asset,
            presetName: AVAssetExportPresetPassthrough
        ) else {
            throw NSError(
                domain: "ClipError",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Failed to initialize passthrough export session"]
            )
        }

        exportSession.outputURL = outputURL
        exportSession.outputFileType = .mp4
        exportSession.timeRange = CMTimeRangeFromTimeToTime(start: startTime, end: endTime)

        if FileManager.default.fileExists(atPath: outputURL.path) {
            try FileManager.default.removeItem(at: outputURL)
        }

        await exportSession.export()

        if exportSession.status != .completed {
            let error = exportSession.error ?? NSError(
                domain: "ClipError",
                code: -2,
                userInfo: [NSLocalizedDescriptionKey: "Unknown export error"]
            )
            throw error
        }
    }
}
