import Foundation
import SwiftUI
import Combine

@MainActor
public final class AppState: ObservableObject {
    public static let shared = AppState()

    @Published public var currentLANIP: String? = nil
    @Published public var selectedNavigationTab: NavigationTab = .overview

    public let serviceManager: ServiceProcessManager
    public let logStore: LogStore
    public let tokenManager: TokenManager
    public let jobMonitor: JobStoreMonitor
    public let installer: EnvironmentInstaller
    public var preferences: UserPreferences

    public enum NavigationTab: String, CaseIterable, Identifiable {
        case overview = "概览"
        case jobs = "转写任务"
        case logs = "运行日志"
        case setup = "环境配置"
        case settings = "偏好设置"

        public var id: String { rawValue }

        public var icon: String {
            switch self {
            case .overview: return "waveform.badge.magnifyingglass"
            case .jobs: return "list.bullet.rectangle"
            case .logs: return "terminal"
            case .setup: return "wrench.and.screwdriver"
            case .settings: return "gearshape"
            }
        }
    }

    public convenience init() {
        self.init(
            serviceManager: .shared,
            logStore: .shared,
            tokenManager: .shared,
            jobMonitor: .shared,
            installer: .shared,
            preferences: .shared
        )
    }

    public init(
        serviceManager: ServiceProcessManager,
        logStore: LogStore,
        tokenManager: TokenManager,
        jobMonitor: JobStoreMonitor,
        installer: EnvironmentInstaller,
        preferences: UserPreferences
    ) {
        self.serviceManager = serviceManager
        self.logStore = logStore
        self.tokenManager = tokenManager
        self.jobMonitor = jobMonitor
        self.installer = installer
        self.preferences = preferences

        refreshNetworkInfo()
        refreshServiceState()
        jobMonitor.startMonitoring()
    }

    /// Refresh LAN network address.
    public func refreshNetworkInfo() {
        self.currentLANIP = NetworkManager.getPrimaryLANIP()
    }

    public func refreshServiceState() {
        serviceManager.refreshState(
            host: preferences.serverHost,
            port: preferences.serverPort,
            tokenManager: tokenManager
        )
    }

    /// Formatted LAN service URL.
    public var serviceURLString: String {
        NetworkManager.formatServiceURL(ip: currentLANIP, port: preferences.serverPort)
    }

    /// Formatted host:port for iPhone input.
    public var hostPortString: String {
        NetworkManager.formatHostPort(ip: currentLANIP, port: preferences.serverPort)
    }

    /// Handles primary action based on current state.
    public func handlePrimaryAction() {
        switch serviceManager.status {
        case .uninstalled:
            selectedNavigationTab = .setup
        case .stopped:
            serviceManager.startService(
                host: preferences.serverHost,
                port: preferences.serverPort,
                logStore: logStore,
                tokenManager: tokenManager
            )
        case .starting:
            break
        case .running:
            if serviceManager.isExternallyManaged {
                refreshServiceState()
            } else {
                serviceManager.stopService(logStore: logStore)
            }
        case .error:
            serviceManager.startService(
                host: preferences.serverHost,
                port: preferences.serverPort,
                logStore: logStore,
                tokenManager: tokenManager
            )
        }
    }

    /// Triggers auto-start on launch if preference is enabled.
    public func onAppLaunch() {
        refreshNetworkInfo()
        tokenManager.reloadToken()
        jobMonitor.reloadJobs()

        if preferences.autoStartService {
            serviceManager.startService(
                host: preferences.serverHost,
                port: preferences.serverPort,
                logStore: logStore,
                tokenManager: tokenManager
            )
        } else {
            refreshServiceState()
        }
    }
}
