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
            if seconds.isFinite && !seconds.isNaN {
                duration = seconds
            }
        }

        return VideoItem(
            title: url.lastPathComponent,
            fileURL: url,
            duration: duration,
            fileSize: size,
            isHidden: isHidden,
            createdAt: date
        )
    }

    /// 导入外部文件（如相册或系统文件选择器）
    public func importFile(from sourceURL: URL, isHidden: Bool = false) async throws {
        let destFolder = isHidden ? vaultDirectory : documentsDirectory
        let destURL = destFolder.appendingPathComponent(sourceURL.lastPathComponent)

        let shouldStopAccess = sourceURL.startAccessingSecurityScopedResource()
        defer {
            if shouldStopAccess {
                sourceURL.stopAccessingSecurityScopedResource()
            }
        }

        if fileManager.fileExists(atPath: destURL.path) {
            try fileManager.removeItem(at: destURL)
        }
        try fileManager.copyItem(at: sourceURL, to: destURL)
        reloadLibrary()
    }

    /// 将视频移动到保险箱 / 移出保险箱
    public func toggleHideVideo(_ video: VideoItem) async throws {
        let targetFolder = video.isHidden ? documentsDirectory : vaultDirectory
        let targetURL = targetFolder.appendingPathComponent(video.fileURL.lastPathComponent)

        if fileManager.fileExists(atPath: targetURL.path) {
            try fileManager.removeItem(at: targetURL)
        }
        try fileManager.moveItem(at: video.fileURL, to: targetURL)
        reloadLibrary()
    }

    /// 删除视频
    public func deleteVideo(_ video: VideoItem) {
        try? fileManager.removeItem(at: video.fileURL)
        reloadLibrary()
    }
}
