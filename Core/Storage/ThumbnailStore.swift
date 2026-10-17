import AVFoundation
import ImageIO
import UniformTypeIdentifiers

public actor ThumbnailStore {
    public static let shared = ThumbnailStore()
    private var active = 0
    private let memory = NSCache<NSString, CGImage>()
    private let directory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("Thumbnails", isDirectory: true)
    public func image(for video: VideoItem) async -> CGImage? {
        let key = "\(video.id.uuidString)-\(Int(video.createdAt.timeIntervalSince1970))-\(video.fileSize)"
        if let image = memory.object(forKey: key as NSString) { return image }

        if video.isHidden {
            // 私密视频：仅在保险箱解锁状态下在内存中生成并缓存封面，绝不写入公开磁盘缓存
            guard await VaultManager.shared.isUnlocked else { return nil }
            guard video.fileURL.pathExtension.lowercased() != "vault" else { return nil }
            while active >= 2 {
                do { try await Task.sleep(for: .milliseconds(20)) } catch { return nil }
            }
            guard !Task.isCancelled else { return nil }
            active += 1
            defer { active -= 1 }
            let asset = AVURLAsset(url: video.fileURL)
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 480, height: 270)
            let second = min(1, max(0, video.duration / 2))
            var image = try? await generator.image(at: CMTime(seconds: second, preferredTimescale: 600)).image
            if image == nil, !Task.isCancelled {
                image = await Task.detached(priority: .utility) { AV1SoftwareDecoderEngine.extractThumbnail(from: video.fileURL, at: second) }.value
            }
            guard let image, !Task.isCancelled else { return nil }
            memory.countLimit = 64
            memory.totalCostLimit = 24 * 1024 * 1024
            memory.setObject(image, forKey: key as NSString, cost: image.bytesPerRow * image.height)
            return image
        }

        let file = directory.appendingPathComponent(key + ".jpg")
        if let source = CGImageSourceCreateWithURL(file as CFURL, nil), let image = CGImageSourceCreateImageAtIndex(source, 0, nil) { return image }
        while active >= 2 {
            do { try await Task.sleep(for: .milliseconds(20)) } catch { return nil }
        }
        guard !Task.isCancelled else { return nil }
        active += 1
        defer { active -= 1 }
        let asset = AVURLAsset(url: video.fileURL)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 480, height: 270)
        let second = min(1, max(0, video.duration / 2))
        var image = try? await generator.image(at: CMTime(seconds: second, preferredTimescale: 600)).image
        if image == nil, !Task.isCancelled {
            image = await Task.detached(priority: .utility) { AV1SoftwareDecoderEngine.extractThumbnail(from: video.fileURL, at: second) }.value
        }
        guard let image, !Task.isCancelled else { return nil }
        memory.countLimit = 64
        memory.totalCostLimit = 24 * 1024 * 1024
        memory.setObject(image, forKey: key as NSString, cost: image.bytesPerRow * image.height)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if let output = CGImageDestinationCreateWithURL(file as CFURL, UTType.jpeg.identifier as CFString, 1, nil) {
            CGImageDestinationAddImage(output, image, [kCGImageDestinationLossyCompressionQuality: 0.75] as CFDictionary)
            _ = CGImageDestinationFinalize(output)
        }
        return image
    }
    public func clear() { memory.removeAllObjects(); try? FileManager.default.removeItem(at: directory) }
    public func clearMemoryOnly() { memory.removeAllObjects() }
}
