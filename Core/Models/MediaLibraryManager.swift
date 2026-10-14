import Foundation
import AVFoundation
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

@MainActor
public final class MediaLibraryManager: ObservableObject {
    public static let shared = MediaLibraryManager()

    @Published public var videos: [VideoItem] = []
    @Published public var isLoading: Bool = false
    @Published public var isImporting: Bool = false
    @Published public var importStatusText: String = ""
    @Published public var importSuccessMessage: String? = nil
    @Published public var isSuccessMessageError: Bool = false
    @Published public var notificationVideoURL: URL? = nil

    public func showNotification(message: String, isError: Bool = false, videoURL: URL? = nil) {
        importSuccessMessage = message
        isSuccessMessageError = isError
        notificationVideoURL = videoURL
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 3_500_000_000)
            if self.importSuccessMessage == message {
                self.importSuccessMessage = nil
                self.isSuccessMessageError = false
                self.notificationVideoURL = nil
            }
        }
    }

    private let fileManager = FileManager.default

    public var documentsDirectory: URL {
        fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    public var clipsDirectory: URL {
        let dir = documentsDirectory.appendingPathComponent("Clips", isDirectory: true)
        if !fileManager.fileExists(atPath: dir.path) {
            try? fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }

    public var vaultDirectory: URL {
        let dir = documentsDirectory.appendingPathComponent(".Vault", isDirectory: true)
        if !fileManager.fileExists(atPath: dir.path) {
            try? fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }

    private init() {
        reloadLibrary()
    }

    /// 重新扫描所有视频
    public func reloadLibrary() {
        Task {
            isLoading = true
            let scanned = await scanLocalVideos()
            self.videos = scanned
            self.isLoading = false
        }
    }

    private func scanLocalVideos() async -> [VideoItem] {
        var items: [VideoItem] = []
        let allowedExtensions = ["mp4", "mov", "m4v", "mkv", "avi", "webm"]

        // 1. 扫描 Documents 根目录及 Clips 目录
        let urlsToScan = [documentsDirectory, clipsDirectory]
        for baseDir in urlsToScan {
            guard let contents = try? fileManager.contentsOfDirectory(at: baseDir, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey], options: [.skipsHiddenFiles]) else {
                continue
            }

            for url in contents {
                let ext = url.pathExtension.lowercased()
                if allowedExtensions.contains(ext) {
                    if let item = await buildVideoItem(from: url, isHidden: false) {
                        items.append(item)
                    }
                }
            }
        }

        // 2. 扫描 .Vault 隐私目录
        if let vaultContents = try? fileManager.contentsOfDirectory(at: vaultDirectory, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey], options: []) {
            for url in vaultContents {
                let ext = url.pathExtension.lowercased()
                if allowedExtensions.contains(ext) || ext == "vault" {
                    if let item = await buildVideoItem(from: url, isHidden: true) {
                        items.append(item)
                    }
                }
            }
        }

        // 按创建时间倒序
        items.sort { $0.createdAt > $1.createdAt }
        return items
    }

    private func buildVideoItem(from url: URL, isHidden: Bool) async -> VideoItem? {
        let resources = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        let size = Int64(resources?.fileSize ?? 0)
        let date = resources?.contentModificationDate ?? Date()

        let asset = AVURLAsset(url: url)
        var duration: TimeInterval = 0
        if let dur = try? await asset.load(.duration) {
            let seconds = CMTimeGetSeconds(dur)
            if seconds.isFinite && !seconds.isNaN && seconds > 0 {
                duration = seconds
            }
        }
        if duration <= 0, let av1Info = MP4AV1Demuxer.parseAV1Track(from: url) {
            duration = av1Info.duration
        }

        // 关联历史播放进度
        let lastPos = PlaybackHistoryManager.shared.getPlaybackPosition(for: url)

        return VideoItem(
            title: url.lastPathComponent,
            fileURL: url,
            duration: duration,
            fileSize: size,
            isHidden: isHidden,
            createdAt: date,
            lastPlayedPosition: lastPos
        )
    }

    /// 导入单个外部文件（在后台线程执行大文件 IO，避免卡死主线程）
    public func importFile(from sourceURL: URL, isHidden: Bool = false, moveInsteadOfCopy: Bool = false) async throws {
        let destFolder = isHidden ? vaultDirectory : documentsDirectory
        let fileName = sourceURL.lastPathComponent
        let destURL = destFolder.appendingPathComponent(fileName)

        if FileManager.default.fileExists(atPath: destURL.path) {
            SubtitleTaskManager.shared.purgeTasks(for: destURL)
        }

        isImporting = true
        importStatusText = "正在导入 \(fileName)..."

        let hasAccess = sourceURL.startAccessingSecurityScopedResource()
        defer {
            if hasAccess {
                sourceURL.stopAccessingSecurityScopedResource()
            }
        }

        do {
            try await Task.detached(priority: .userInitiated) {
                let fm = FileManager.default
                if fm.fileExists(atPath: destURL.path) {
                    try fm.removeItem(at: destURL)
                }
                if moveInsteadOfCopy {
                    try fm.moveItem(at: sourceURL, to: destURL)
                } else {
                    try fm.copyItem(at: sourceURL, to: destURL)
                }
            }.value

            importStatusText = "正在生成缩略图与媒体索引..."
            let scanned = await scanLocalVideos()
            self.videos = scanned
            isImporting = false
            importSuccessMessage = "已成功导入：\(fileName)"

            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                if self.importSuccessMessage == "已成功导入：\(fileName)" {
                    self.importSuccessMessage = nil
                }
            }
        } catch {
            isImporting = false
            throw error
        }
    }

    /// 批量导入外部文件（用于从文件或相册导入，提供平滑加载 HUD 样式及实时多文件进度）
    public func importFiles(from sourceURLs: [URL], isHidden: Bool = false) async {
        guard !sourceURLs.isEmpty else { return }

        isImporting = true
        importStatusText = "正在准备导入文件..."

        var successCount = 0
        var lastSuccessName = ""

        for (index, sourceURL) in sourceURLs.enumerated() {
            let fileName = sourceURL.lastPathComponent
            importStatusText = sourceURLs.count > 1 ? "正在导入 (\(index + 1)/\(sourceURLs.count)): \(fileName)" : "正在导入: \(fileName)"

            let hasAccess = sourceURL.startAccessingSecurityScopedResource()

            let destFolder = isHidden ? vaultDirectory : documentsDirectory
            let destURL = destFolder.appendingPathComponent(fileName)

            if FileManager.default.fileExists(atPath: destURL.path) {
                SubtitleTaskManager.shared.purgeTasks(for: destURL)
            }

            do {
                try await Task.detached(priority: .userInitiated) {
                    let fm = FileManager.default
                    if fm.fileExists(atPath: destURL.path) {
                        try fm.removeItem(at: destURL)
                    }
                    try fm.copyItem(at: sourceURL, to: destURL)
                }.value
                successCount += 1
                lastSuccessName = fileName
            } catch {
                print("导入文件失败: \(fileName), error: \(error)")
            }

            if hasAccess {
                sourceURL.stopAccessingSecurityScopedResource()
            }
        }

        importStatusText = "正在生成缩略图与媒体索引..."
        let scanned = await scanLocalVideos()
        self.videos = scanned

        // 保留至少 300ms 动画平滑过渡，避免瞬间闪退
        try? await Task.sleep(nanoseconds: 300_000_000)
        isImporting = false

        if successCount > 0 {
            if successCount == 1 {
                importSuccessMessage = "已成功导入：\(lastSuccessName)"
            } else {
                importSuccessMessage = "已成功导入 \(successCount) 个视频文件"
            }

            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                self.importSuccessMessage = nil
            }
        }
    }

    /// 将视频移动到保险箱（支持真实 AES-256 加密落盘）/ 移出保险箱
    public func toggleHideVideo(_ video: VideoItem) async throws {
        SubtitleTaskManager.shared.purgeTasks(for: video.fileURL)
        if video.isHidden {
            // 移出保险箱 -> 解密回 Documents
            let destName = video.fileURL.lastPathComponent.replacingOccurrences(of: ".vault", with: "")
            let targetURL = documentsDirectory.appendingPathComponent(destName)
            if fileManager.fileExists(atPath: targetURL.path) {
                try fileManager.removeItem(at: targetURL)
            }
            if video.fileURL.pathExtension.lowercased() == "vault" {
                try VaultManager.shared.decryptFile(at: video.fileURL, destinationURL: targetURL)
                try? fileManager.removeItem(at: video.fileURL)
            } else {
                try fileManager.moveItem(at: video.fileURL, to: targetURL)
            }
        } else {
            // 移入保险箱 -> 进行 AES 加密保护并修改扩展名为 .vault
            let destName = video.fileURL.lastPathComponent + ".vault"
            let targetURL = vaultDirectory.appendingPathComponent(destName)
            if fileManager.fileExists(atPath: targetURL.path) {
                try fileManager.removeItem(at: targetURL)
            }
            try VaultManager.shared.encryptFile(at: video.fileURL, destinationURL: targetURL)
            try? fileManager.removeItem(at: video.fileURL)
        }
        reloadLibrary()
    }

    /// 删除视频
    public func deleteVideo(_ video: VideoItem) {
        SubtitleTaskManager.shared.purgeTasks(for: video.fileURL)
        try? fileManager.removeItem(at: video.fileURL)
        reloadLibrary()
    }
}
