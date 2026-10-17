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
        let name = source.lastPathComponent + (isHidden ? ".vault" : "")
        let destination = SafeFileImport.availableURL(name: name, in: folder)
        if isHidden {
            let sourceItem = await buildVideoItem(from: source, isHidden: false)
            try await VaultManager.shared.encryptFile(at: source, destinationURL: destination)
            let resource = try destination.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            MediaIdentityStore.shared.update(destination, size: Int64(resource.fileSize ?? 0), modified: resource.contentModificationDate ?? Date(), duration: sourceItem?.duration ?? 0)
        } else {
            let task = Task.detached(priority: .utility) { try SafeFileImport.copy(source, to: destination) }
            try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
        }
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

        let targetFolder = video.isHidden ? documentsDirectory : vaultDirectory
        if let capacityValues = try? targetFolder.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
           let availableBytes = capacityValues.volumeAvailableCapacityForImportantUsage {
            let requiredBytes = video.fileSize + 50 * 1024 * 1024
            if availableBytes < requiredBytes {
                let requiredStr = ByteCountFormatter.string(fromByteCount: requiredBytes, countStyle: .file)
                let availableStr = ByteCountFormatter.string(fromByteCount: availableBytes, countStyle: .file)
                throw NSError(domain: "MediaLibrary", code: 3, userInfo: [
                    NSLocalizedDescriptionKey: "存储空间不足：转移该视频需要至少 \(requiredStr) 可用空间，当前仅剩余 \(availableStr)"
                ])
            }
        }

        #if os(iOS)
        var backgroundTaskID = UIBackgroundTaskIdentifier.invalid
        backgroundTaskID = UIApplication.shared.beginBackgroundTask(withName: "VaultVideoTransfer") {
            UIApplication.shared.endBackgroundTask(backgroundTaskID)
            backgroundTaskID = .invalid
        }
        defer {
            if backgroundTaskID != .invalid {
                UIApplication.shared.endBackgroundTask(backgroundTaskID)
                backgroundTaskID = .invalid
            }
        }
        #endif

        isImporting = true
        importStatusText = video.isHidden ? "正在准备移出私密文件夹…" : "正在准备移入私密文件夹…"
        defer {
            isImporting = false
            importStatusText = ""
        }
        SubtitleTaskManager.shared.pauseTasks(for: source)
        let document = SubtitleCacheStore().load(for: source)
        let identity = MediaIdentityStore.shared.id(for: source)
        let companionDirectory = vaultDirectory.appendingPathComponent(".Subtitles", isDirectory: true).appendingPathComponent(identity.uuidString, isDirectory: true)
        var archivedCompanions: [URL] = []
        let name = video.isHidden && source.pathExtension == "vault" ? source.deletingPathExtension().lastPathComponent : source.lastPathComponent
        let destination = SafeFileImport.availableURL(name: name + (video.isHidden ? "" : ".vault"), in: video.isHidden ? documentsDirectory : vaultDirectory)
        var committed = false
        var createdDestination = false
        var newCompanions: [URL] = []
        defer {
            if !committed {
                if createdDestination { try? fileManager.removeItem(at: destination) }
                for file in newCompanions { try? fileManager.removeItem(at: file) }
            }
        }
        final class ProgressDebouncer: @unchecked Sendable {
            private var lastReportedPercent: Int = -1
            private let lock = NSLock()
            func shouldUpdate(pct: Double) -> (should: Bool, percent: Int) {
                lock.lock()
                defer { lock.unlock() }
                let percent = Int(pct * 100)
                if percent != lastReportedPercent || percent == 100 {
                    lastReportedPercent = percent
                    return (true, percent)
                }
                return (false, percent)
            }
        }
        let debouncer = ProgressDebouncer()
        let isHiding = !video.isHidden
        let progressHandler: @Sendable (Double) -> Void = { pct in
            let (shouldUpdate, percent) = debouncer.shouldUpdate(pct: pct)
            guard shouldUpdate else { return }
            Task { @MainActor in
                MediaLibraryManager.shared.importStatusText = isHiding
                    ? "正在加密并移入私密文件夹 (\(percent)%)…"
                    : "正在解密并移出私密文件夹 (\(percent)%)…"
            }
        }
        if video.isHidden {
            if source.pathExtension == "vault" { try await VaultManager.shared.decryptFile(at: source, destinationURL: destination, progress: progressHandler) }
            else { try await Task.detached { try SafeFileImport.copy(source, to: destination) }.value }
        } else { try await VaultManager.shared.encryptFile(at: source, destinationURL: destination, progress: progressHandler) }
        createdDestination = true
        if !video.isHidden {
            let base = source.deletingPathExtension()
            let companions = ["srt", "ass", "external.json", "external.srt", "external.ass", "source.srt", "bilingual.srt", "zh-Hans.srt", "zh.srt", "ja.srt", "en.srt", "lovort-subtitles.json"].map { base.appendingPathExtension($0) }.filter { fileManager.fileExists(atPath: $0.path) }
            if !companions.isEmpty { try fileManager.createDirectory(at: companionDirectory, withIntermediateDirectories: true) }
            let publicLegacyCaches = SubtitleCacheStore().cacheCandidates(for: source).filter {
                $0.path.hasPrefix(documentsDirectory.path + "/") && fileManager.fileExists(atPath: $0.path) && !companions.contains($0)
            }
            if !publicLegacyCaches.isEmpty { try fileManager.createDirectory(at: companionDirectory, withIntermediateDirectories: true) }
            for file in companions + publicLegacyCaches {
                let encrypted = SafeFileImport.availableURL(name: file.lastPathComponent + ".vault", in: companionDirectory)
                try await VaultManager.shared.encryptFile(at: file, destinationURL: encrypted)
                newCompanions.append(encrypted)
                archivedCompanions.append(file)
            }
        } else if let files = try? fileManager.contentsOfDirectory(at: companionDirectory, includingPropertiesForKeys: nil) {
            let oldBase = source.deletingPathExtension().deletingPathExtension().lastPathComponent
            let newBase = destination.deletingPathExtension().lastPathComponent
            for encrypted in files where encrypted.pathExtension == "vault" {
                let originalName = encrypted.deletingPathExtension().lastPathComponent
                guard originalName.hasPrefix(oldBase + ".") else { continue }
                let name = newBase + String(originalName.dropFirst(oldBase.count))
                let restored = SafeFileImport.availableURL(name: name, in: documentsDirectory)
                try await VaultManager.shared.decryptFile(at: encrypted, destinationURL: restored)
                newCompanions.append(restored)
            }
        }
        // Retain source and destination on removal failure; never silently discard user data.
        do { try fileManager.removeItem(at: source) }
        catch { reloadLibrary(); throw error }
        committed = true
        SubtitleTaskManager.shared.relocateTasks(from: source, to: destination, isPrivate: !video.isHidden)
        var cleanupFailed = false
        for file in archivedCompanions { do { try fileManager.removeItem(at: file) } catch { cleanupFailed = true } }
        if cleanupFailed { showNotification(message: "视频已加密，但部分原字幕文件未能移除，请检查“文件”中的字幕副本。", isError: true) }
        if video.isHidden { try? fileManager.removeItem(at: companionDirectory) }
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
