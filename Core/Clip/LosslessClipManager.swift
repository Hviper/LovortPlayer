import Foundation
import AVFoundation
#if os(iOS)
import Photos
#endif

private final class ClipSessionBox: @unchecked Sendable {
    let session: AVAssetExportSession
    init(_ session: AVAssetExportSession) { self.session = session }
}

public enum ClipExportStrategy: String, CaseIterable, Sendable, Hashable {
    case fastCopy
    case frameAccurate
    public var title: String { self == .fastCopy ? "快速复制" : "精确裁切" }
}

public enum ClipExportMode: Sendable, Equatable {
    case streamCopy
    case reencoded
}

public struct ClipSegment: Identifiable, Sendable, Equatable {
    public let id: UUID
    public var start: TimeInterval
    public var end: TimeInterval
    public init(id: UUID = UUID(), start: TimeInterval, end: TimeInterval) {
        self.id = id
        self.start = start
        self.end = end
    }
}

public final class LosslessClipManager: @unchecked Sendable {
    public static let shared = LosslessClipManager()

    private init() {}

    /// Fast copy may align to keyframes; frame-accurate export re-encodes.
    public func exportLosslessClip(
        assetURL: URL,
        outputURL: URL,
        startTime: CMTime,
        endTime: CMTime,
        saveToPhotos: Bool = true,
        strategy: ClipExportStrategy = .fastCopy
    ) async throws -> ClipExportMode {
        let asset = AVURLAsset(url: assetURL)
        
        // 确保父目录存在
        let parentDir = outputURL.deletingLastPathComponent()
        if !FileManager.default.fileExists(atPath: parentDir.path) {
            try? FileManager.default.createDirectory(at: parentDir, withIntermediateDirectories: true)
        }

        // 检查 Passthrough 兼容性，如不兼容则使用 HighestQuality 兼容性编码
        let presets = await AVAssetExportSession.exportPresets(compatibleWith: asset)
        let copy = strategy == .fastCopy && presets.contains(AVAssetExportPresetPassthrough)
        let preset = copy ? AVAssetExportPresetPassthrough : AVAssetExportPresetHighestQuality

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

        guard !FileManager.default.fileExists(atPath: outputURL.path) else { throw CocoaError(.fileWriteFileExists) }
        let box = ClipSessionBox(exportSession)
        do {
            try await withTaskCancellationHandler {
                try await exportSession.export(to: outputURL, as: .mp4)
            } onCancel: { box.session.cancelExport() }
            try Task.checkCancellation()
        } catch { try? FileManager.default.removeItem(at: outputURL); throw error }

        #if os(iOS)
        // 尝试自动保存一份到系统相册
        if saveToPhotos { try? await VideoExportManager.shared.saveToPhotoLibrary(videoURL: outputURL) }
        #endif
        return copy ? .streamCopy : .reencoded
    }
}
