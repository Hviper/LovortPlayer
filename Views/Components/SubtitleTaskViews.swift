import SwiftUI

public struct FloatingSubtitleTaskCapsule: View {
    public let task: SubtitleTaskItem
    public let onOpen: () -> Void

    public init(task: SubtitleTaskItem, onOpen: @escaping () -> Void) {
        self.task = task
        self.onOpen = onOpen
    }

    public var body: some View {
        Button(action: onOpen) {
            HStack(spacing: 12) {
                ZStack {
                    Circle().fill(Color.cyan.opacity(0.18))
                    Image(systemName: "captions.bubble.fill")
                        .foregroundColor(.cyan)
                }
                .frame(width: 40, height: 40)

                VStack(alignment: .leading, spacing: 6) {
                    Text(task.videoTitle)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.white)
                        .lineLimit(1)
                    Text(task.statusText)
                        .font(.system(size: 11))
                        .foregroundColor(.white.opacity(0.62))
                        .lineLimit(1)
                    HStack(spacing: 6) {
                        stageProgress(value: task.transcriptionProgress, color: .cyan)
                        stageProgress(value: task.translationProgress, color: .purple)
                    }
                }

                Text("\(Int(task.overallProgress * 100))%")
                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                    .foregroundColor(.white)
                Image(systemName: "chevron.up")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(.white.opacity(0.45))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            .background(.ultraThinMaterial)
            .environment(\.colorScheme, .dark)
            .clipShape(RoundedRectangle(cornerRadius: 18))
            .overlay(RoundedRectangle(cornerRadius: 18).stroke(Color.white.opacity(0.12), lineWidth: 1))
            .shadow(color: .black.opacity(0.38), radius: 16, y: 8)
        }
        .buttonStyle(.plain)
    }

    private func stageProgress(value: Double, color: Color) -> some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.1))
                Capsule().fill(color).frame(width: proxy.size.width * min(1, max(0, value)))
            }
        }
        .frame(height: 3)
    }
}

public struct SubtitleTaskCenterView: View {
    @ObservedObject private var manager = SubtitleTaskManager.shared
    @Environment(\.dismiss) private var dismiss

    public init() {}

    public var body: some View {
        NavigationStack {
            ZStack {
                Color(red: 0.04, green: 0.04, blue: 0.05).ignoresSafeArea()
                if manager.tasks.isEmpty {
                    ContentUnavailableView(
                        "暂无字幕任务",
                        systemImage: "captions.bubble",
                        description: Text("在视频卡片菜单中选择“生成双语字幕”即可加入任务队列。")
                    )
                    .foregroundStyle(.white.opacity(0.7))
                } else {
                    ScrollView {
                        LazyVStack(spacing: 12) {
                            ForEach(sortedTasks) { task in
                                taskCard(task)
                            }
                        }
                        .padding(16)
                    }
                }
            }
            .navigationTitle("字幕任务")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
    }

    private var sortedTasks: [SubtitleTaskItem] {
        manager.tasks.sorted {
            if $0.phase.isActive != $1.phase.isActive { return $0.phase.isActive }
            return $0.updatedAt > $1.updatedAt
        }
    }

    private func taskCard(_ task: SubtitleTaskItem) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(task.videoTitle)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(.white)
                        .lineLimit(2)
                    Label(task.phase.displayName, systemImage: phaseIcon(task.phase))
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(phaseColor(task.phase))
                }
                Spacer()
                Text("\(Int(task.overallProgress * 100))%")
                    .font(.system(size: 13, weight: .bold, design: .monospaced))
                    .foregroundColor(.white.opacity(0.8))
            }

            Text(task.statusText)
                .font(.system(size: 12))
                .foregroundColor(.white.opacity(0.58))
                .fixedSize(horizontal: false, vertical: true)

            progressRow(
                title: "原文转写",
                detail: task.totalChunks > 0 ? "\(task.completedChunks)/\(task.totalChunks) 分片" : stageDetail(task.transcriptionProgress),
                progress: task.transcriptionProgress,
                color: .cyan
            )
            progressRow(
                title: "中文翻译",
                detail: task.totalTranslationBatches > 0 ? "\(task.translatedBatches)/\(task.totalTranslationBatches) 批" : stageDetail(task.translationProgress),
                progress: task.translationProgress,
                color: .purple
            )

            if let error = task.errorMessage, !error.isEmpty {
                Text(error)
                    .font(.system(size: 11))
                    .foregroundColor(.orange.opacity(0.9))
            }

            HStack(spacing: 10) {
                if task.phase.isActive {
                    Button("暂停") { manager.pause(task.id) }
                        .buttonStyle(.bordered)
                } else if [.pausedByUser, .pausedBySystem, .failed, .sourceReady, .cancelled].contains(task.phase) {
                    Button(task.phase == .failed || task.phase == .sourceReady ? "重试" : "继续") {
                        manager.resume(task.id)
                    }
                    .buttonStyle(.borderedProminent)
                }

                if task.phase.isActive || task.phase == .pausedByUser || task.phase == .pausedBySystem {
                    Button("取消", role: .destructive) { manager.cancel(task.id) }
                        .buttonStyle(.bordered)
                }

                Spacer()

                if !task.phase.isActive {
                    Button(role: .destructive) { manager.removeFinished(task.id) } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.borderless)
                }
            }
            .tint(AppSettings.shared.themeColor.color)
        }
        .padding(15)
        .background(RoundedRectangle(cornerRadius: 16).fill(Color.white.opacity(0.055)))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.white.opacity(0.08), lineWidth: 1))
    }

    private func progressRow(title: String, detail: String, progress: Double, color: Color) -> some View {
        VStack(spacing: 5) {
            HStack {
                Text(title).font(.system(size: 11, weight: .medium)).foregroundColor(.white.opacity(0.68))
                Spacer()
                Text(detail).font(.system(size: 10, design: .monospaced)).foregroundColor(.white.opacity(0.4))
            }
            ProgressView(value: min(1, max(0, progress)))
                .tint(color)
        }
    }

    private func stageDetail(_ progress: Double) -> String {
        progress > 0 ? "\(Int(progress * 100))%" : "等待中"
    }

    private func phaseIcon(_ phase: SubtitleTaskPhase) -> String {
        switch phase {
        case .completed: return "checkmark.seal.fill"
        case .sourceReady: return "text.bubble.fill"
        case .failed: return "exclamationmark.triangle.fill"
        case .pausedByUser, .pausedBySystem: return "pause.circle.fill"
        case .cancelled: return "xmark.circle"
        default: return "waveform.and.mic"
        }
    }

    private func phaseColor(_ phase: SubtitleTaskPhase) -> Color {
        switch phase {
        case .completed: return .green
        case .sourceReady: return .cyan
        case .failed: return .orange
        case .cancelled: return .red.opacity(0.8)
        default: return AppSettings.shared.themeColor.color
        }
    }
}
