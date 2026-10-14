import AVFoundation
import Foundation

private final class SubtitleExportSessionBox: @unchecked Sendable {
    let session: AVAssetExportSession
    init(_ session: AVAssetExportSession) { self.session = session }
}

@MainActor
public final class SubtitleVideoExporter {
    public static let shared = SubtitleVideoExporter()
    private var leases: [URL: Int] = [:]
    private var retired: Set<URL> = []
    private let cacheDirectory: URL
    init(cacheDirectory: URL? = nil) {
        self.cacheDirectory = cacheDirectory ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
    }

    private var exportRoot: URL { cacheDirectory.appendingPathComponent("SubtitleVideoExports", isDirectory: true) }

    public func retain(_ url: URL) { leases[url, default: 0] += 1 }
    public func release(_ url: URL) {
        leases[url] = max(0, (leases[url] ?? 0) - 1)
        if leases[url] == 0 { leases[url] = nil; if retired.contains(url) { retire(url) } }
    }
    public func retire(_ url: URL) {
        let directory = url.deletingLastPathComponent()
        guard directory.deletingLastPathComponent().standardizedFileURL == exportRoot.standardizedFileURL,
              UUID(uuidString: directory.lastPathComponent) != nil else { return }
        if leases[url, default: 0] > 0 { retired.insert(url); return }
        try? FileManager.default.removeItem(at: directory)
        retired.remove(url)
    }
    /// Remove abandoned outputs from interrupted app sessions, leaving recent shares intact.
    public func cleanupExpired() {
        guard let directories = try? FileManager.default.contentsOfDirectory(at: exportRoot,
            includingPropertiesForKeys: [.creationDateKey, .isSymbolicLinkKey]) else { return }
        for directory in directories where UUID(uuidString: directory.lastPathComponent) != nil {
            guard let values = try? directory.resourceValues(forKeys: [.creationDateKey, .isSymbolicLinkKey]),
                  values.isSymbolicLink != true, let created = values.creationDate,
                  Date().timeIntervalSince(created) > 86_400,
                  !leases.keys.contains(where: { $0.deletingLastPathComponent() == directory }) else { continue }
            try? FileManager.default.removeItem(at: directory)
        }
    }

    public func export(videoURL: URL, lines: [SubtitleLine], mode: SubtitleVideoExportMode,
                       textMode: SubtitleExportTextMode = .bilingual,
                       onProgress: (@MainActor @Sendable (Double) -> Void)? = nil) async throws -> URL {
        try Task.checkCancellation()
        cleanupExpired()
        let access = videoURL.startAccessingSecurityScopedResource()
        defer { if access { videoURL.stopAccessingSecurityScopedResource() } }
        let readable = try await VaultManager.shared.readableURL(for: videoURL)
        defer { VaultManager.shared.releaseReadableURL(readable) }
        let asset = AVURLAsset(url: readable)
        let duration = try await asset.load(.duration)
        let cues = try SubtitleExportTimeline.make(lines: lines, duration: duration.seconds, textMode: textMode)
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        guard let video = videoTracks.first else { throw SubtitleVideoExportError.unsupportedVideo }
        let naturalSize = try await video.load(.naturalSize)
        let transform = try await video.load(.preferredTransform)
        let transformed = CGRect(origin: .zero, size: naturalSize).applying(transform).standardized
        guard transformed.width > 0, transformed.height > 0 else { throw SubtitleVideoExportError.unsupportedVideo }
        let directory = cacheDirectory
            .appendingPathComponent("SubtitleVideoExports", isDirectory: true).appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        #if os(iOS)
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: directory.path)
        #endif
        let output = directory.appendingPathComponent(mode == .embedded ? "内嵌字幕.mp4" : "烧录字幕.mp4")
        do {
            let composition = AVMutableComposition()
            let fullRange = CMTimeRange(start: .zero, duration: duration)
            for track in [video] + (try await asset.loadTracks(withMediaType: .audio)) {
                try Task.checkCancellation()
                guard let destination = composition.addMutableTrack(withMediaType: track.mediaType, preferredTrackID: kCMPersistentTrackID_Invalid) else {
                    throw SubtitleVideoExportError.failed("无法创建音视频轨道")
                }
                let range = CMTimeRangeGetIntersection(try await track.load(.timeRange), otherRange: fullRange)
                if range.duration > .zero { try destination.insertTimeRange(range, of: track, at: range.start) }
                if track.mediaType == .video { destination.preferredTransform = transform }
            }
            if mode == .embedded {
                try await MP4SubtitleTrackWriter.mux(asset: composition, cues: cues, size: transformed.size, to: output, onProgress: onProgress)
                try await validate(output: output, embedded: true)
                onProgress?(1)
                return output
            }
            try Task.checkCancellation()
            let presets = AVAssetExportSession.exportPresets(compatibleWith: composition)
            let preset: String
            if presets.contains(AVAssetExportPresetHighestQuality) { preset = AVAssetExportPresetHighestQuality }
            else { preset = AVAssetExportPreset1920x1080 }
            guard let session = AVAssetExportSession(asset: composition, presetName: preset), session.supportedFileTypes.contains(.mp4) else {
                throw SubtitleVideoExportError.unsupportedVideo
            }
            session.outputURL = output
            session.outputFileType = .mp4
            session.shouldOptimizeForNetworkUse = true
            if mode == .burnedIn {
                let renderer = SubtitleBurnInRenderer(cues: cues)
                session.videoComposition = try await AVVideoComposition.videoComposition(with: composition, applyingCIFiltersWithHandler: { request in
                    do {
                        let image = try renderer.image(at: request.compositionTime.seconds, over: request.sourceImage)
                        request.finish(with: image, context: nil)
                    } catch { request.finish(with: error) }
                })
            }
            let box = SubtitleExportSessionBox(session)
            let progressTask = Task { @MainActor in
                while !Task.isCancelled {
                    onProgress?(Double(box.session.progress))
                    try? await Task.sleep(for: .milliseconds(250))
                }
            }
            defer { progressTask.cancel() }
            try await withTaskCancellationHandler {
                try await session.export(to: output, as: .mp4)
            } onCancel: { box.session.cancelExport() }
            try Task.checkCancellation()
            try await validate(output: output, embedded: false)
            onProgress?(1)
            return output
        } catch {
            try? FileManager.default.removeItem(at: directory)
            if Task.isCancelled { throw CancellationError() }
            throw error
        }
    }
    private func validate(output: URL, embedded: Bool) async throws {
        let result = AVURLAsset(url: output)
        guard !(try await result.loadTracks(withMediaType: .video)).isEmpty else { throw SubtitleVideoExportError.failed("输出缺少视频轨道") }
        if embedded, (try await result.loadTracks(withMediaType: .subtitle)).isEmpty {
            throw SubtitleVideoExportError.failed("输出缺少字幕轨道")
        }
    }

}
