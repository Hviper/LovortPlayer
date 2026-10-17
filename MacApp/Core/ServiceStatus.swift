import SwiftUI

/// Represents the high-level state of the Mac subtitle transcription service.
public enum ServiceStatus: String, CaseIterable, Identifiable, Sendable {
    case uninstalled = "未安装"
    case stopped = "已停止"
    case starting = "启动中"
    case running = "运行中"
    case error = "异常"

    public var id: String { rawValue }

    public var displayName: String { rawValue }

    public var sfSymbol: String {
        switch self {
        case .uninstalled:
            return "wrench.and.screwdriver"
        case .stopped:
            return "pause.circle.fill"
        case .starting:
            return "arrow.triangle.2.circlepath.circle.fill"
        case .running:
            return "checkmark.circle.fill"
        case .error:
            return "exclamationmark.octagon.fill"
        }
    }

    public var menuBarSymbol: String {
        switch self {
        case .uninstalled:
            return "waveform.badge.exclamationmark"
        case .stopped:
            return "waveform"
        case .starting:
            return "waveform.circle"
        case .running:
            return "waveform.badge.checkmark"
        case .error:
            return "waveform.badge.xmark"
        }
    }

    public var statusColor: Color {
        switch self {
        case .uninstalled:
            return .orange
        case .stopped:
            return .secondary
        case .starting:
            return .blue
        case .running:
            return .green
        case .error:
            return .red
        }
    }

    public var primaryActionTitle: String {
        switch self {
        case .uninstalled:
            return "一键配置环境"
        case .stopped:
            return "启动服务"
        case .starting:
            return "正在启动..."
        case .running:
            return "停止服务"
        case .error:
            return "重新启动"
        }
    }

    public var isActionEnabled: Bool {
        switch self {
        case .starting:
            return false
        default:
            return true
        }
    }
}
