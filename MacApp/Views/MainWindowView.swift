import SwiftUI
import AppKit

public struct MainWindowView: View {
    @ObservedObject var appState: AppState

    public init(appState: AppState) {
        self.appState = appState
    }

    public var body: some View {
        NavigationSplitView {
            sidebarContent
                .navigationSplitViewColumnWidth(min: 190, ideal: 210, max: 240)
        } detail: {
            detailContent
                .toolbar {
                    ToolbarItemGroup(placement: .automatic) {
                        StatusBadgeView(status: appState.serviceManager.status)

                        Button {
                            appState.handlePrimaryAction()
                        } label: {
                            HStack(spacing: 4) {
                                if appState.serviceManager.status == .starting {
                                    ProgressView().controlSize(.small)
                                }
                                Text(primaryActionTitle)
                            }
                        }
                        .disabled(!appState.serviceManager.status.isActionEnabled)

                        Button {
                            appState.refreshNetworkInfo()
                            appState.refreshServiceState()
                            appState.tokenManager.reloadToken()
                            appState.jobMonitor.reloadJobs()
                        } label: {
                            Image(systemName: "arrow.clockwise")
                        }
                        .help("刷新状态与网络")
                    }
                }
        }
        .frame(minWidth: 720, idealWidth: 850, minHeight: 520, idealHeight: 620)
    }

    private var primaryActionTitle: String {
        if appState.serviceManager.status == .running,
           appState.serviceManager.isExternallyManaged {
            return "重新检测"
        }
        return appState.serviceManager.status.primaryActionTitle
    }

    private var sidebarContent: some View {
        VStack(spacing: 0) {
            // App Branding
            HStack(spacing: 10) {
                Image(systemName: "waveform.circle.fill")
                    .font(.system(size: 28))
                    .foregroundColor(.accentColor)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Lovort 字幕服务")
                        .font(.headline)
                    Text("Mac 离线转写后台")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)

            Divider()

            // Tab List
            List(AppState.NavigationTab.allCases, selection: $appState.selectedNavigationTab) { tab in
                NavigationLink(value: tab) {
                    HStack {
                        Label(tab.rawValue, systemImage: tab.icon)
                        Spacer()
                        if tab == .jobs && !appState.jobMonitor.jobs.isEmpty {
                            Text("\(appState.jobMonitor.jobs.count)")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.secondary.opacity(0.15))
                                .clipShape(Capsule())
                        } else if tab == .setup && appState.serviceManager.status == .uninstalled {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundColor(.orange)
                                .font(.caption)
                        }
                    }
                }
            }
            .listStyle(.sidebar)

            Spacer()

            Divider()

            // Sidebar Footer Info
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 4) {
                    Text("局域网 IP:")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                    Text(appState.currentLANIP ?? "未连接")
                        .font(.system(.caption2, design: .monospaced, weight: .medium))
                }
                HStack(spacing: 4) {
                    Text("监听端口:")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                    Text(verbatim: String(appState.preferences.serverPort))
                        .font(.system(.caption2, design: .monospaced, weight: .medium))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(Color(NSColor.controlBackgroundColor).opacity(0.4))
        }
    }

    @ViewBuilder
    private var detailContent: some View {
        switch appState.selectedNavigationTab {
        case .overview:
            OverviewView(appState: appState)
        case .jobs:
            JobsView(appState: appState)
        case .logs:
            LogView(logStore: appState.logStore)
        case .setup:
            EnvironmentSetupView(appState: appState)
        case .settings:
            SettingsView(appState: appState)
        }
    }
}
