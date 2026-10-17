import SwiftUI
import AppKit

public struct MenuBarView: View {
    @ObservedObject var appState: AppState
    let openMainWindow: () -> Void

    public init(appState: AppState, openMainWindow: @escaping () -> Void) {
        self.appState = appState
        self.openMainWindow = openMainWindow
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Status row
            HStack(spacing: 6) {
                Circle()
                    .fill(appState.serviceManager.status.statusColor)
                    .frame(width: 8, height: 8)
                Text("状态: \(appState.serviceManager.status.displayName)")
                    .font(.headline)
            }

            if appState.serviceManager.status == .running {
                Text(appState.hostPortString)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Divider()

            // Open Main Window action
            Button {
                openMainWindow()
            } label: {
                Label("显示主窗口", systemImage: "macwindow")
            }

            // Start / Stop action
            if appState.serviceManager.status == .running {
                if appState.serviceManager.isExternallyManaged {
                    Button {
                        appState.refreshServiceState()
                    } label: {
                        Label("重新检测状态", systemImage: "arrow.clockwise")
                    }
                } else {
                    Button {
                        appState.serviceManager.stopService(logStore: appState.logStore)
                    } label: {
                        Label("停止服务", systemImage: "stop.circle")
                    }
                }
            } else if appState.serviceManager.status == .stopped || appState.serviceManager.status == .error {
                Button {
                    appState.serviceManager.startService(
                        host: appState.preferences.serverHost,
                        port: appState.preferences.serverPort,
                        logStore: appState.logStore,
                        tokenManager: appState.tokenManager
                    )
                } label: {
                    Label("启动服务", systemImage: "play.circle")
                }
            } else if appState.serviceManager.status == .uninstalled {
                Button {
                    appState.selectedNavigationTab = .setup
                    openMainWindow()
                } label: {
                    Label("配置运行环境...", systemImage: "wrench.and.screwdriver")
                }
            }

            Divider()

            // Auto-start preference toggle
            Toggle("打开 App 时自动启动服务", isOn: $appState.preferences.autoStartService)

            Divider()

            // Quit action
            Button("退出") {
                appState.serviceManager.terminateOnAppQuit()
                NSApplication.shared.terminate(nil)
            }
            .keyboardShortcut("q", modifiers: .command)
        }
    }
}
