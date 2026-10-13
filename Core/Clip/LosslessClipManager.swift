import Foundation
import AVFoundation
#if os(iOS)
import Photos
#endif

public final class LosslessClipManager: @unchecked Sendable {
    public static let shared = LosslessClipManager()

    private init() {}

    /// 无损精准截取视频（使用 Passthrough GOP 极速复制码流，不经过重编码）
    public func exportLosslessClip(
        assetURL: URL,
        outputURL: URL,
        startTime: CMTime,
        endTime: CMTime
    ) async throws {
        let asset = AVURLAsset(url: assetURL)
        
        // 确保父目录存在
        let parentDir = outputURL.deletingLastPathComponent()
        if !FileManager.default.fileExists(atPath: parentDir.path) {
            try? FileManager.default.createDirectory(at: parentDir, withIntermediateDirectories: true)
        }

        // 检查 Passthrough 兼容性，如不兼容则使用 HighestQuality 兼容性编码
        let presets = await AVAssetExportSession.exportPresets(compatibleWith: asset)
        let preset = presets.contains(AVAssetExportPresetPassthrough) ? AVAssetExportPresetPassthrough : AVAssetExportPresetHighestQuality

        guard let exportSession = AVAssetExportSession(
            asset: asset,
            presetName: preset
        ) else {
            throw NSError(
                domain: "ClipError",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "无法初始化视频导出器"]
            )
        }

        exportSession.outputURL = outputURL
        exportSession.outputFileType = .mp4
        exportSession.timeRange = CMTimeRangeFromTimeToTime(start: startTime, end: endTime)

        if FileManager.default.fileExists(atPath: outputURL.path) {
            try? FileManager.default.removeItem(at: outputURL)
        }

        await exportSession.export()

        if exportSession.status != .completed {
            let error = exportSession.error ?? NSError(
                domain: "ClipError",
                code: -2,
                userInfo: [NSLocalizedDescriptionKey: "剪辑导出失败: \(exportSession.error?.localizedDescription ?? "未知错误")"]
            )
            throw error
        }

        #if os(iOS)
        // 尝试自动保存一份到系统相册
        try? await VideoExportManager.shared.saveToPhotoLibrary(videoURL: outputURL)
        #endif
    }
}
