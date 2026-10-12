import SwiftUI

public struct VideoCardView: View {
    public let video: VideoItem
    public var onSelect: () -> Void

    public init(video: VideoItem, onSelect: @escaping () -> Void) {
        self.video = video
        self.onSelect = onSelect
    }

    public var body: some View {
        Button(action: onSelect) {
            VStack(alignment: .leading, spacing: 10) {
                // 16:9 封面卡片 (Lovort 极简黑白灰风格)
                ZStack(alignment: .bottomTrailing) {
                    RoundedRectangle(cornerRadius: 16)
                        .fill(
                            LinearGradient(
                                colors: [Color.white.opacity(0.08), Color.white.opacity(0.02)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .aspectRatio(16/9, contentMode: .fit)
                        .overlay(
                            Image(systemName: "play.fill")
                                .font(.system(size: 26))
                                .foregroundColor(.white.opacity(0.4))
                        )

                    // 时长与分辨率 Tag
                    HStack(spacing: 4) {
                        Text(formatDuration(video.duration))
                            .font(.system(size: 11, weight: .semibold, design: .monospaced))
                            .foregroundColor(.white)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.black.opacity(0.65))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .padding(10)
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

                        Text("AI 字幕就绪")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(.cyan.opacity(0.9))
                    }
                }
                .padding(.horizontal, 4)
            }
            .padding(8)
            .background(
                RoundedRectangle(cornerRadius: 20)
                    .fill(Color.white.opacity(0.03))
                    .overlay(
                        RoundedRectangle(cornerRadius: 20)
                            .stroke(Color.white.opacity(0.06), lineWidth: 1)
                    )
            )
        }
        .buttonStyle(.plain)
    }

    private func formatDuration(_ duration: TimeInterval) -> String {
        let mins = Int(duration) / 60
        let secs = Int(duration) % 60
        return String(format: "%02d:%02d", mins, secs)
    }

    private func formatFileSize(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useMB, .useGB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }
}
