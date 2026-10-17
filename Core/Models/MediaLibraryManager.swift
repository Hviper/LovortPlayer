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

    private var scanTask: Task<Void, Never>?
    private var scanGeneration = UUID()

    /// Cancel stale scans and reuse unchanged metadata/identities.
    public func reloadLibrary() {
        scanTask?.cancel()
        let generation = UUID()
        scanGeneration = generation
        scanTask = Task {
            isLoading = true
            let scanned = await scanLocalVideos()
            guard !Task.isCancelled, generation == scanGeneration else { return }
            videos = scanned
            isLoading = false
        }
    }

    public func refreshPlaybackPositions() {
        for index in videos.indices { videos[index].lastPlayedPosition = PlaybackHistoryManager.shared.getPlaybackPosition(for: videos[index].fileURL) }
    }

    private func scanLocalVideos() async -> [VideoItem] {
        var items: [VideoItem] = []
        let allowedExtensions = ["mp4", "mov", "m4v", "mkv", "avi", "webm"]

        // 1. 扫描 Documents 根目录及 Clips 目录
        let urlsToScan = [documentsDirectory, clipsDirectory]
        for baseDir in urlsToScan {
            guard let contents = await Task.detached(priority: .utility, operation: { try? FileManager.default.contentsOfDirectory(at: baseDir, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey], options: [.skipsHiddenFiles]) }).value else {
                continue
            }

            for url in contents {
                if Task.isCancelled { return items }
                let ext = url.pathExtension.lowercased()
                if allowedExtensions.contains(ext) {
                    if let item = await buildVideoItem(from: url, isHidden: false) {
                        items.append(item)
                    }
                }
            }
        }

        // 2. 扫描 .Vault 隐私目录
        let privateDirectory = vaultDirectory
        if let vaultContents = await Task.detached(priority: .utility, operation: { try? FileManager.default.contentsOfDirectory(at: privateDirectory, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey], options: []) }).value {
            for url in vaultContents {
                if Task.isCancelled { return items }
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
        let cachedDuration = MediaIdentityStore.shared.cachedDuration(for: url, size: size, modified: date)
        var duration: TimeInterval = cachedDuration ?? 0
        if cachedDuration == nil, url.pathExtension != "vault", let dur = try? await asset.load(.duration) {
            let seconds = CMTimeGetSeconds(dur)
            if seconds.isFinite && !seconds.isNaN && seconds > 0 {
                duration = seconds
            }
        }
        if cachedDuration == nil, duration <= 0, url.pathExtension != "vault" {
            duration = await Task.detached(priority: .utility) { MP4AV1Demuxer.parseAV1Track(from: url)?.duration ?? 0 }.value
        }
        MediaIdentityStore.shared.update(url, size: size, modified: date, duration: duration)

        // 关联历史播放进度
        let lastPos = PlaybackHistoryManager.shared.getPlaybackPosition(for: url)

        return VideoItem(
            id: MediaIdentityStore.shared.id(for: url),
            title: url.lastPathComponent,
            fileURL: url,
            duration: duration,
            fileSize: size,
            isHidden: isHidden,
            createdAt: date,
            lastPlayedPosition: lastPos
        )
    }

    private func ingest(_ source: URL, isHidden: Bool, removeSource: Bool = false) async throws -> URL {
        let access = source.startAccessingSecurityScopedResource()
        defer { if access { source.stopAccessingSecurityScopedResource() } }
        let folder = isHidden ? vaultDirectory : documentsDirectory
        let name = source.lastPathComponent
        let destination = SafeFileImport.availableURL(name: name, in: folder)
        let task = Task.detached(priority: .utility) { try SafeFileImport.copy(source, to: destination) }
        try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
        let resource = try destination.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        let sourceItem = await buildVideoItem(from: destination, isHidden: isHidden)
        MediaIdentityStore.shared.update(destination, size: Int64(resource.fileSize ?? 0), modified: resource.contentModificationDate ?? Date(), duration: sourceItem?.duration ?? 0)
        // Removing a temporary transfer source is safe only after a complete destination exists.
        if removeSource, source.standardizedFileURL != destination.standardizedFileURL { try? fileManager.removeItem(at: source) }
        return destination
    }

    public func importFile(from sourceURL: URL, isHidden: Bool = false, moveInsteadOfCopy: Bool = false) async throws {
        guard !isImporting else { throw CocoaError(.fileWriteFileExists) }
        isImporting = true
        defer { isImporting = false }
        importStatusText = "正在导入 \(sourceURL.lastPathComponent)…"
        let destination = try await ingest(sourceURL, isHidden: isHidden, removeSource: moveInsteadOfCopy)
        reloadLibrary()
        showNotification(message: "已导入：\(destination.lastPathComponent)", videoURL: destination)
    }

    public func importFiles(from sourceURLs: [URL], isHidden: Bool = false) async {
        guard !sourceURLs.isEmpty, !isImporting else { return }
        isImporting = true
        defer { isImporting = false }
        var success = 0
        var failed: [String] = []
        for (index, source) in sourceURLs.enumerated() {
            importStatusText = "正在导入 \(index + 1)/\(sourceURLs.count)：\(source.lastPathComponent)"
            do { _ = try await ingest(source, isHidden: isHidden); success += 1 }
            catch { failed.append(source.lastPathComponent) }
        }
        reloadLibrary()
        showNotification(message: failed.isEmpty ? "已导入 \(success) 个视频" : "已导入 \(success) 个，失败 \(failed.count) 个：\(failed.prefix(3).joined(separator: "、"))。原文件保留，可重新选择导入。", isError: !failed.isEmpty)
    }

    private var movingVideos: Set<URL> = []

    public func toggleHideVideo(_ video: VideoItem) async throws {
        guard !isImporting else { throw NSError(domain: "MediaLibrary", code: 2, userInfo: [NSLocalizedDescriptionKey: "正在处理其他文件，请稍候"]) }
        let source = video.fileURL
        guard movingVideos.insert(source).inserted else { throw NSError(domain: "MediaLibrary", code: 1, userInfo: [NSLocalizedDescriptionKey: "该视频正在移动，请稍后再试"]) }
        defer { movingVideos.remove(source) }

        SubtitleTaskManager.shared.pauseTasks(for: source)
        let document = SubtitleCacheStore().load(for: source)
        let identity = MediaIdentityStore.shared.id(for: source)
        let companionDirectory = vaultDirectory.appendingPathComponent(".Subtitles", isDirectory: true).appendingPathComponent(identity.uuidString, isDirectory: true)

        let targetFolder = video.isHidden ? documentsDirectory : vaultDirectory
        // 移出或移入私密文件夹：保留原始扩展名（如 mp4），不再追加 .vault 后缀
        let cleanName = source.pathExtension.lowercased() == "vault" ? source.deletingPathExtension().lastPathComponent : source.lastPathComponent
        let destination = SafeFileImport.availableURL(name: cleanName, in: targetFolder)

        if source.pathExtension.lowercased() == "vault" {
            // 兼容已存在的旧 .vault 加密文件：在移出时自动解密还原为原始明文视频格式
            isImporting = true
            importStatusText = "正在恢复视频格式…"
            defer {
                isImporting = false
                importStatusText = ""
            }
            try await VaultManager.shared.decryptFile(at: source, destinationURL: destination)
            try? fileManager.removeItem(at: source)
        } else {
            // 正常视频文件：APFS 毫秒级直接移动到隐藏/公开目录，无损、秒移、无需暴力加密重写
            try fileManager.moveItem(at: source, to: destination)
        }

        if !video.isHidden {
            // 移入私密文件夹：伴随字幕直接移入私密子目录，不破坏性加密
            let base = source.deletingPathExtension()
            let companions = ["srt", "ass", "external.json", "external.srt", "external.ass", "source.srt", "bilingual.srt", "zh-Hans.srt", "zh.srt", "ja.srt", "en.srt", "lovort-subtitles.json"].map { base.appendingPathExtension($0) }.filter { fileManager.fileExists(atPath: $0.path) }
            if !companions.isEmpty {
                try fileManager.createDirectory(at: companionDirectory, withIntermediateDirectories: true)
                for file in companions {
                    let destFile = SafeFileImport.availableURL(name: file.lastPathComponent, in: companionDirectory)
                    try? fileManager.moveItem(at: file, to: destFile)
                }
            }
        } else if let files = try? fileManager.contentsOfDirectory(at: companionDirectory, includingPropertiesForKeys: nil) {
            // 移出私密文件夹：伴随字幕移回 documentsDirectory
            let oldBase = cleanName.components(separatedBy: ".").first ?? cleanName
            let newBase = destination.deletingPathExtension().lastPathComponent
            for companion in files {
                let originalName = companion.lastPathComponent
                let targetName: String
                if originalName.hasPrefix(oldBase + ".") {
                    targetName = newBase + String(originalName.dropFirst(oldBase.count))
                } else {
                    targetName = originalName
                }
                let cleanSubtitleName = targetName.hasSuffix(".vault") ? String(targetName.dropLast(6)) : targetName
                let restored = SafeFileImport.availableURL(name: cleanSubtitleName, in: documentsDirectory)
                if companion.pathExtension.lowercased() == "vault" {
                    try? await VaultManager.shared.decryptFile(at: companion, destinationURL: restored)
                    try? fileManager.removeItem(at: companion)
                } else {
                    try? fileManager.moveItem(at: companion, to: restored)
                }
            }
            try? fileManager.removeItem(at: companionDirectory)
        }

        SubtitleTaskManager.shared.relocateTasks(from: source, to: destination, isPrivate: !video.isHidden)
        MediaIdentityStore.shared.transfer(from: source, to: destination)
        let resource = try destination.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        MediaIdentityStore.shared.update(destination, size: Int64(resource.fileSize ?? 0), modified: resource.contentModificationDate ?? Date(), duration: video.duration)

        if let document {
            let rebound = SubtitleDocument(sourceLanguage: document.sourceLanguage, targetLanguage: document.targetLanguage,
                engine: document.engine, model: document.model, translationProvider: document.translationProvider,
                translationConfiguration: document.translationConfiguration, isComplete: document.isComplete ?? true,
                translationComplete: document.translationComplete, gptEnhanced: document.gptEnhanced,
                completedChunkIndexes: document.completedChunkIndexes, chunkDuration: document.chunkDuration,
                videoURL: destination, lines: document.lines)
            _ = try? SubtitleCacheStore().save(rebound, for: destination)
        }

        reloadLibrary()
        showNotification(message: video.isHidden ? "已移出私密文件夹" : "已移入私密文件夹", videoURL: destination)
    }

    /// 自动将历史已有的 .vault 加密视频平滑解密还原为正常音视频文件
    public func migrateLegacyVaultFiles() async {
        guard VaultManager.shared.isUnlocked else { return }
        let privateDirectory = vaultDirectory
        guard let files = try? fileManager.contentsOfDirectory(at: privateDirectory, includingPropertiesForKeys: nil) else { return }
        let vaultFiles = files.filter { $0.pathExtension.lowercased() == "vault" }
        guard !vaultFiles.isEmpty else { return }

        for file in vaultFiles {
            let originalName = file.deletingPathExtension().lastPathComponent
            let destination = SafeFileImport.availableURL(name: originalName, in: privateDirectory)
            do {
                try await VaultManager.shared.decryptFile(at: file, destinationURL: destination)
                try? fileManager.removeItem(at: file)
                MediaIdentityStore.shared.transfer(from: file, to: destination)
            } catch {
                print("Failed to auto-migrate legacy vault file: \(file.lastPathComponent), error: \(error)")
            }
        }
        reloadLibrary()
    }

    public func deleteVideo(_ video: VideoItem) {
        guard !movingVideos.contains(video.fileURL) else { showNotification(message: "该视频正在移动，请稍后再删除", isError: true); return }
        do {
            try fileManager.removeItem(at: video.fileURL)
            SubtitleTaskManager.shared.purgeTasks(for: video.fileURL)
            PlaylistStore.shared.removeVideo(video.id)
            MediaIdentityStore.shared.remove(video.fileURL)
            videos.removeAll { $0.id == video.id }
        } catch { showNotification(message: "删除失败：\(error.localizedDescription)", isError: true) }
    }
}
