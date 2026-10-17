import SwiftUI
import AppKit

public struct SettingsView: View {
    @ObservedObject var appState: AppState
    @ObservedObject var preferences: UserPreferences

    public init(appState: AppState) {
        self.appState = appState
        self.preferences = appState.preferences
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                // Header
                VStack(alignment: .leading, spacing: 4) {
                    Text("偏好设置")
                        .font(.title2)
                        .fontWeight(.bold)
                    Text("配置服务启动选项、网络端口及持久化数据路径。")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }

                // Service Startup Settings Card
                VStack(alignment: .leading, spacing: 14) {
                    Text("启动行为")
                        .font(.headline)

                    Toggle(isOn: $preferences.autoStartService) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("打开 App 时自动启动服务")
                                .font(.subheadline)
                                .fontWeight(.medium)
                            Text("在应用开启时检测环境就绪状态并自动拉起转写服务。")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                    .toggleStyle(.checkbox)
                }
                .padding(16)
                .background(Color(NSColor.controlBackgroundColor))
                .cornerRadius(12)
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(Color(NSColor.separatorColor), lineWidth: 0.5)
                )

                // Network Port Card
                VStack(alignment: .leading, spacing: 14) {
                    Text("网络与监听设置")
                        .font(.headline)

                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("服务监听端口")
                                .font(.subheadline)
                            Text("默认 8765。若与其他本地服务冲突可修改，修改后需重启服务并在 iPhone 端对应更新。")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        Spacer()
                        TextField("8765", value: $preferences.serverPort, format: .number.grouping(.never))
                            .frame(width: 80)
                            .multilineTextAlignment(.trailing)
                            .textFieldStyle(.roundedBorder)
                    }

                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("服务监听地址")
                                .font(.subheadline)
                            Text("默认 0.0.0.0 接受局域网入站请求。")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        Spacer()
                        TextField("0.0.0.0", text: $preferences.serverHost)
                            .frame(width: 100)
                            .multilineTextAlignment(.trailing)
                            .textFieldStyle(.roundedBorder)
                    }
                }
                .padding(16)
                .background(Color(NSColor.controlBackgroundColor))
                .cornerRadius(12)
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(Color(NSColor.separatorColor), lineWidth: 0.5)
                )

                // Storage Directories Card
                VStack(alignment: .leading, spacing: 14) {
                    Text("存储与兼容路径")
                        .font(.headline)

                    Text("所有运行时生成的数据均存放于用户主目录的可写规范路径中，保证与现有 CLI 及 iPhone 客户端 100% 兼容。")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    pathRow(
                        title: "鉴权口令文件 (Token)",
                        path: ResourceLocator.defaultTokenFileURL.path,
                        revealURL: ResourceLocator.defaultTokenFileURL.deletingLastPathComponent()
                    )

                    pathRow(
                        title: "转写任务记录 (Jobs)",
                        path: ResourceLocator.defaultJobsDirectoryURL.path,
                        revealURL: ResourceLocator.defaultJobsDirectoryURL
                    )

                    pathRow(
                        title: "独立虚拟环境 (Venv)",
                        path: ResourceLocator.managedVenvDirectory.path,
                        revealURL: ResourceLocator.managedVenvDirectory
                    )

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
    }

    private func pathRow(title: String, path: String, revealURL: URL) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                    .font(.subheadline)
                    .fontWeight(.medium)
                Spacer()
                Button {
                    let fm = FileManager.default
                    if !fm.fileExists(atPath: revealURL.path) {
                        try? fm.createDirectory(at: revealURL, withIntermediateDirectories: true)
                    }
                    NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: revealURL.path)
                } label: {
                    Label("在访达中显示", systemImage: "folder")
                        .font(.caption2)
                }
                .buttonStyle(.plain)
                .foregroundColor(.accentColor)
            }

            Text(path)
                .font(.system(.caption, design: .monospaced))
                .foregroundColor(.secondary)
                .textSelection(.enabled)
        }
        .padding(.vertical, 4)
    }
}
