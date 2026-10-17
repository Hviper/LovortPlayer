import SwiftUI
import AppKit

public struct JobsView: View {
    @ObservedObject var appState: AppState
    @ObservedObject var monitor: JobStoreMonitor

    public init(appState: AppState) {
        self.appState = appState
        self.monitor = appState.jobMonitor
    }

    public var body: some View {
        VStack(spacing: 0) {
            // Header bar
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 8) {
                        Text("转写任务")
                            .font(.headline)
                        Text("\(monitor.jobs.count)")
                            .font(.caption)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.secondary.opacity(0.15))
                            .clipShape(Capsule())
                    }
                    Text("持久化任务存放于 ~/.local/share/lovort-mac-subtitles/jobs")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Spacer()

                Button {
                    monitor.revealInFinder()
                } label: {
                    Label("在访达中显示", systemImage: "folder")
                        .font(.caption)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Button {
                    monitor.reloadJobs()
                } label: {
                    Label("刷新", systemImage: "arrow.clockwise")
                        .font(.caption)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
            .background(Color(NSColor.controlBackgroundColor))

            Divider()

            if monitor.jobs.isEmpty {
                emptyStateView
            } else {
                ScrollView {
                    LazyVStack(spacing: 12) {
                        ForEach(monitor.jobs) { job in
                            jobRow(job)
                        }
                    }
                    .padding(20)
                }
            }
        }
        .onAppear {
            monitor.startMonitoring()
        }
        .onDisappear {
            monitor.stopMonitoring()
        }
    }

    private var emptyStateView: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "waveform.badge.magnifyingglass")
                .font(.system(size: 42))
                .foregroundColor(.secondary.opacity(0.5))

            Text("暂无转写任务")
                .font(.title3)
                .fontWeight(.medium)
                .foregroundColor(.primary)

            Text("当 iPhone 上传音轨后，Mac 会在此创建持久化任务并按 4 分钟切片进行 Metal 转写。\n即使手机中途断开连接，Mac 也会持续完成并在手机返回时提供结果。")
                .font(.caption)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .lineSpacing(4)
                .frame(maxWidth: 420)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(30)
    }

    private func jobRow(_ job: TranscriptionJob) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            // Top row
            HStack(spacing: 8) {
                Text("任务 ID:")
                    .font(.caption)
                    .foregroundColor(.secondary)

                Text(job.id)
                    .font(.system(.subheadline, design: .monospaced, weight: .medium))
                    .textSelection(.enabled)

                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(job.id, forType: .string)
                } label: {
                    Image(systemName: "doc.on.doc")
                        .font(.caption2)
                }
                .buttonStyle(.plain)
                .help("复制任务 ID")

                Spacer()

                if let lang = job.language, !lang.isEmpty {
                    Text(lang.uppercased())
                        .font(.caption2)
                        .fontWeight(.semibold)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.accentColor.opacity(0.12))
                        .foregroundColor(.accentColor)
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                }

                HStack(spacing: 4) {
                    Image(systemName: job.status.sfSymbol)
                    Text(job.status.displayName)
                }
                .font(.caption)
                .fontWeight(.medium)
                .foregroundColor(job.status.statusColor)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(job.status.statusColor.opacity(0.12))
                .clipShape(Capsule())
            }

            // Progress bar & text
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(job.segmentProgressDescription)
                        .font(.caption)
                        .foregroundColor(.secondary)

                    Spacer()

                    Text(job.progressPercentageText)
                        .font(.system(.caption, design: .monospaced, weight: .semibold))
                }

                ProgressView(value: job.progressPercentage)
                    .tint(job.status.statusColor)
            }

            // Error display if failed
            if let errorText = job.error, !errorText.isEmpty {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.red)
                        .font(.caption)
                    Text(errorText)
                        .font(.caption)
                        .foregroundColor(.red)
                        .lineLimit(3)
                        .textSelection(.enabled)
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.red.opacity(0.08))
                .cornerRadius(6)
            }

            // Footer
            HStack {
                Text("已提取 \(job.segmentsCount) 条字幕片段")
                    .font(.caption2)
                    .foregroundColor(.secondary)

                Spacer()

                Text("更新时间: \(job.formattedUpdatedAt)")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
        }
        .padding(14)
        .background(Color(NSColor.controlBackgroundColor))
        .cornerRadius(10)
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color(NSColor.separatorColor), lineWidth: 0.5)
        )
    }
}
