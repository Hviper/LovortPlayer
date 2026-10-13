import SwiftUI
import AVFoundation

public struct VideoCardView: View {
    public let video: VideoItem
    public var onSelect: () -> Void
    public var onToggleHide: (() -> Void)? = nil
    public var onDelete: (() -> Void)? = nil

    @State private var thumbnail: Image? = nil

    public init(
        video: VideoItem,
        onSelect: @escaping () -> Void,
        onToggleHide: (() -> Void)? = nil,
        onDelete: (() -> Void)? = nil
    ) {
        self.video = video
        self.onSelect = onSelect
        self.onToggleHide = onToggleHide
        self.onDelete = onDelete
    }

    private var progressRatio: Double {
        guard video.duration > 0, video.lastPlayedPosition > 0 else { return 0 }
        return min(1.0, max(0.0, video.lastPlayedPosition / video.duration))
    }

    public var body: some View {
        Button(action: onSelect) {
            VStack(alignment: .leading, spacing: 10) {
                // 16:9 封面卡片 (Lovort 极简黑白灰风格，支持自动提取缩略图与历史进度指示)
                ZStack(alignment: .bottom) {
                    Group {
                        if let thumbnail = thumbnail {
                            thumbnail
                                .resizable()
                                .aspectRatio(16/9, contentMode: .fill)
                        } else {
                            LinearGradient(
                                colors: [Color.white.opacity(0.08), Color.white.opacity(0.02)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                            .aspectRatio(16/9, contentMode: .fit)
                            .overlay(
                                Image(systemName: "play.fill")
                                    .font(.system(size: 26))
                                    .foregroundColor(.white.opacity(0.35))
                            )
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 16))

                    // 底部进度条与标签覆盖层
                    VStack(spacing: 0) {
                        HStack {
                            Spacer()
                            // 时长 Tag
                            HStack(spacing: 4) {
                                Text(formatDuration(video.duration))
                                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                                    .foregroundColor(.white)
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Color.black.opacity(0.75))
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                            .padding(10)
                        }

                        // 历史进度条指示器
                        if progressRatio > 0 {
                            GeometryReader { geo in
                                ZStack(alignment: .leading) {
                                    Rectangle()
                                        .fill(Color.white.opacity(0.2))
                                        .frame(height: 3)

                                    Rectangle()
                                        .fill(Color.cyan)
                                        .frame(width: geo.size.width * progressRatio, height: 3)
                                }
                            }
                            .frame(height: 3)
                            .clipShape(RoundedRectangle(cornerRadius: 2))
                        }
                    }
                }

                // 标题与信息元数据
                VStack(alignment: .leading, spacing: 4) {
                    Text(video.title)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(.white)
                        .lineLimit(1)

                    HStack(spacing: 8) {
                        Text(formatFileSize(video.fileSize))
                            .font(.system(size: 12))
                            .foregroundColor(.white.opacity(0.5))

                        Text("•")
                            .foregroundColor(.white.opacity(0.3))

                        if video.lastPlayedPosition > 0 {
                            Text("上次看到 \(formatDuration(video.lastPlayedPosition))")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundColor(.cyan.opacity(0.9))
                        } else {
                            Text(video.isHidden ? "私密文件" : "AI 字幕就绪")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundColor(video.isHidden ? .yellow.opacity(0.9) : .white.opacity(0.4))
                        }
                    }
                }
                .padding(.horizontal, 4)
            }
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: 20)
                    .fill(Color.white.opacity(0.04))
                    .overlay(
                        RoundedRectangle(cornerRadius: 20)
                            .stroke(Color.white.opacity(0.07), lineWidth: 1)
                    )
            )
        }
        .buttonStyle(.plain)
        .contextMenu {
            if let onToggleHide = onToggleHide {
                Button(action: onToggleHide) {
                    Label(video.isHidden ? "移出私密文件夹" : "移入私密文件夹", systemImage: video.isHidden ? "lock.open" : "lock.fill")
                }
            }
            if let onDelete = onDelete {
                Button(role: .destructive, action: onDelete) {
                    Label("删除视频", systemImage: "trash")
                }
            }
        }
        .task {
            await generateThumbnail()
        }
    }

    private func generateThumbnail() async {
        guard thumbnail == nil else { return }
        let fileURL = video.fileURL
        let asset = AVURLAsset(url: fileURL)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 480, height: 270)
        let targetSec = video.lastPlayedPosition > 1 ? video.lastPlayedPosition : min(1.0, max(0, video.duration / 2))
        let time = CMTime(seconds: targetSec, preferredTimescale: 600)

        var resolvedCGImage: CGImage? = try? await generator.image(at: time).image
        if resolvedCGImage == nil {
            resolvedCGImage = await Task.detached(priority: .utility) {
                AV1SoftwareDecoderEngine.extractThumbnail(from: fileURL, at: targetSec)
            }.value
        }

        if let cgImage = resolvedCGImage {
            #if os(iOS)
            self.thumbnail = Image(uiImage: UIImage(cgImage: cgImage))
            #elseif os(macOS)
            let rep = NSBitmapImageRep(cgImage: cgImage)
            let nsImage = NSImage(size: NSSize(width: cgImage.width, height: cgImage.height))
            nsImage.addRepresentation(rep)
            self.thumbnail = Image(nsImage: nsImage)
            #endif
        }
    }

    private func formatDuration(_ duration: TimeInterval) -> String {
        guard duration > 0 else { return "00:00" }
        let mins = Int(duration) / 60
        let secs = Int(duration) % 60
        return String(format: "%02d:%02d", mins, secs)
    }

    private func formatFileSize(_ bytes: Int64) -> String {
        guard bytes > 0 else { return "未知大小" }
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useMB, .useGB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }
}
