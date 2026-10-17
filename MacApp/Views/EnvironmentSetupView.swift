import SwiftUI
import AppKit

public struct EnvironmentSetupView: View {
    @ObservedObject var appState: AppState
    @ObservedObject var installer: EnvironmentInstaller

    public init(appState: AppState) {
        self.appState = appState
        self.installer = appState.installer
    }

    private var report: EnvironmentReport? {
        appState.serviceManager.environmentReport
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                // Header
                VStack(alignment: .leading, spacing: 6) {
                    Text("环境配置与依赖管理")
                        .font(.title2)
                        .fontWeight(.bold)
                    Text("服务运行依赖 Apple Silicon 硬件、Python 3 环境以及 ffmpeg 音频处理工具。")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }

                // Preflight Checklist Card
                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        Text("系统前提条件检查")
                            .font(.headline)
                        Spacer()
                        Button {
                            appState.refreshServiceState()
                        } label: {
                            Label("重新检测", systemImage: "arrow.clockwise")
                                .font(.caption)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }

                    Divider()

                    checkItemRow(
                        title: "Apple Silicon 架构 (M 系列芯片)",
                        isSatisfied: report?.isAppleSilicon == true,
                        detail: report?.isAppleSilicon == true ? "已检测到 Apple Silicon 硬件加速支持" : "当前设备非 Apple Silicon，MLX Whisper 无法启用",
                        remedy: nil
                    )

                    checkItemRow(
                        title: "Python 3 解释器",
                        isSatisfied: report?.pythonPath != nil,
                        detail: report?.pythonPath != nil ? "\(report!.pythonPath!) (\(report?.pythonVersion ?? "未知版本"))" : "未检测到 Python 3 解释器",
                        remedy: "请通过 Homebrew 安装：brew install python@3.11"
                    )

                    checkItemRow(
                        title: "ffmpeg 音频处理工具",
                        isSatisfied: report?.ffmpegPath != nil,
                        detail: report?.ffmpegPath != nil ? report!.ffmpegPath! : "未检测到 ffmpeg 工具",
                        remedy: "请通过 Homebrew 安装：brew install ffmpeg"
                    )

                    checkItemRow(
                        title: "ffprobe 媒体分析工具",
                        isSatisfied: report?.ffprobePath != nil,
                        detail: report?.ffprobePath != nil ? report!.ffprobePath! : "未检测到 ffprobe 工具",
                        remedy: "安装 ffmpeg 后通常自带 ffprobe：brew install ffmpeg"
                    )

                    checkItemRow(
                        title: "专用 Python 虚拟环境与依赖",
                        isSatisfied: report?.isVenvReady == true,
                        detail: report?.isVenvReady == true ? "已就绪 (\(report?.venvPythonPath ?? ""))" : "尚未创建或缺少 mlx-whisper 依赖包",
                        remedy: "点击下方按钮一键初始化"
                    )
                }
                .padding(16)
                .background(Color(NSColor.controlBackgroundColor))
                .cornerRadius(12)
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(Color(NSColor.separatorColor), lineWidth: 0.5)
                )

                // Missing prerequisites alert if any
                if let report = report, !report.hasRequiredSystemTools || !report.isHardwareReady {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 6) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundColor(.orange)
                            Text("缺少系统工具或硬件限制")
                                .font(.subheadline)
                                .fontWeight(.semibold)
                        }

                        Text("根据安全规范，本应用不会自动安装 Homebrew 或执行高权限系统变更。请先手动执行以下命令，完成后点击右上角“重新检测”：")
                            .font(.caption)
                            .foregroundColor(.secondary)

                        HStack {
                            Text("brew install ffmpeg")
                                .font(.system(.caption, design: .monospaced))
                                .padding(8)
                                .background(Color(NSColor.textBackgroundColor))
                                .cornerRadius(6)

                            Button {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString("brew install ffmpeg", forType: .string)
                            } label: {
                                Image(systemName: "doc.on.doc")
                                    .font(.caption)
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }
                    }
                    .padding(14)
                    .background(Color.orange.opacity(0.08))
                    .cornerRadius(8)
                }

                // One-click install action card
                VStack(alignment: .leading, spacing: 12) {
                    Text("虚拟环境管理")
                        .font(.headline)

                    Text("应用将在 \(ResourceLocator.managedVenvDirectory.path) 创建独立的 Python 虚拟环境，并安装 mlx-whisper 运行依赖。无需污染系统全局 Python。")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    if installer.isInstalling {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack(spacing: 8) {
                                ProgressView()
                                    .controlSize(.small)
                                Text(installer.currentStage)
                                    .font(.subheadline)
                                    .fontWeight(.medium)
                            }

                            Text("正在下载与构建依赖，这可能需要 1~3 分钟。可切换至“运行日志”标签查看实时输出。")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        .padding(12)
                        .background(Color.accentColor.opacity(0.08))
                        .cornerRadius(8)
                    }

                    if let err = installer.errorMessage {
                        HStack(alignment: .top, spacing: 6) {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundColor(.red)
                            Text(err)
                                .font(.caption)
                                .foregroundColor(.red)
                        }
                        .padding(10)
                        .background(Color.red.opacity(0.08))
                        .cornerRadius(6)
                    }

                    HStack(spacing: 12) {
                        Button {
                            performInstall()
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "arrow.down.circle.fill")
                                Text(report?.isVenvReady == true ? "重新安装/更新环境" : "一键配置虚拟环境与依赖")
                                    .fontWeight(.semibold)
                            }
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(installer.isInstalling || report?.hasRequiredSystemTools != true || report?.isHardwareReady != true)

                        if installer.isInstalling {
                            Button("取消") {
                                installer.cancel()
                            }
                            .buttonStyle(.bordered)
                        }
                    }
                }
                .padding(16)
                .background(Color(NSColor.controlBackgroundColor))
                .cornerRadius(12)
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(Color(NSColor.separatorColor), lineWidth: 0.5)
                )
            }
            .padding(20)
        }
        .onAppear {
            appState.refreshServiceState()
        }
    }

    private func checkItemRow(title: String, isSatisfied: Bool, detail: String, remedy: String?) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: isSatisfied ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundColor(isSatisfied ? .green : .red)
                .font(.title3)

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.subheadline)
                    .fontWeight(.medium)

                Text(detail)
                    .font(.caption)
                    .foregroundColor(.secondary)

                if !isSatisfied, let remedy = remedy {
                    Text(remedy)
                        .font(.caption2)
                        .foregroundColor(.orange)
                }
            }

            Spacer()
        }
    }

    private func performInstall() {
        guard let pythonPath = report?.pythonPath else { return }
        let venvURL = ResourceLocator.managedVenvDirectory
        guard let reqURL = ResourceLocator.resolveRequirementsTxt() else {
            appState.logStore.append(rawLine: "[错误] 未找到 requirements.txt 文件", isError: true)
            return
        }

        Task {
            let success = await installer.installEnvironment(
                pythonPath: pythonPath,
                venvURL: venvURL,
                requirementsURL: reqURL,
                logStore: appState.logStore
            )
            appState.refreshServiceState()
            if success {
                appState.selectedNavigationTab = .overview
            }
        }
    }
}
