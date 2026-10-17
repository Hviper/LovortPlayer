import SwiftUI

public struct OverviewView: View {
    @ObservedObject var appState: AppState

    public init(appState: AppState) {
        self.appState = appState
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                // MARK: - Service Status Card
                statusCard

                // MARK: - Connection & Security Section
                VStack(alignment: .leading, spacing: 14) {
                    Text("连接与鉴权")
                        .font(.headline)
                        .foregroundColor(.primary)

                    CopyableFieldView(
                        title: "iPhone 连接地址 (Host:Port)",
                        value: appState.hostPortString,
                        hint: "填入 iPhone 设置 → 局域网 Mac 字幕服务",
                        icon: "iphone.gen3"
                    )

                    CopyableFieldView(
                        title: "完整 HTTP 服务 URL",
                        value: appState.serviceURLString,
                        hint: "端口 \(appState.preferences.serverPort)",
                        icon: "network"
                    )

                    CopyableFieldView(
                        title: "访问口令 (X-Lovort-Token)",
                        value: appState.tokenManager.token,
                        isSecret: true,
                        hint: "存储于 ~/.config/lovort-mac-subtitles/token",
                        icon: "key.fill"
                    )
                }
                .padding(16)
                .background(Color(NSColor.controlBackgroundColor).opacity(0.6))
                .cornerRadius(12)
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(Color(NSColor.separatorColor), lineWidth: 0.5)
                )

                // MARK: - Model & Engine Specifications
                VStack(alignment: .leading, spacing: 12) {
                    Text("推理模型与规格")
                        .font(.headline)
                        .foregroundColor(.primary)

                    HStack(spacing: 24) {
                        specItem(title: "模型", value: "Whisper Large V3 Turbo", subvalue: "mlx-community/whisper-large-v3-turbo")
                        Divider()
                        specItem(title: "硬件加速", value: "Apple Silicon Metal", subvalue: "MLX 统一内存并行推理")
                        Divider()
                        specItem(title: "切片规则", value: "240 秒 (4分钟) / 片段", subvalue: "支持手机断开后台续做")
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(16)
                .background(Color(NSColor.controlBackgroundColor).opacity(0.6))
                .cornerRadius(12)
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(Color(NSColor.separatorColor), lineWidth: 0.5)
                )

                // MARK: - Security Notice
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "lock.shield")
                        .foregroundColor(.secondary)
                        .font(.title3)

                    VStack(alignment: .leading, spacing: 4) {
                        Text("安全与局域网提示")
                            .font(.subheadline)
                            .fontWeight(.medium)

                        Text("本服务通过局域网 HTTP 传输音频与口令，没有传输加密。请仅在可信家庭私有 Wi-Fi 中使用；私密视频请在手机本机端使用离线 Whisper 转写。")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.secondary.opacity(0.08))
                .cornerRadius(8)
            }
            .padding(20)
        }
        .onAppear {
            appState.refreshNetworkInfo()
            appState.tokenManager.reloadToken()
        }
    }

    private var statusCard: some View {
        HStack(alignment: .center, spacing: 16) {
            Image(systemName: appState.serviceManager.status.sfSymbol)
                .font(.system(size: 36))
                .foregroundColor(appState.serviceManager.status.statusColor)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text("服务状态")
                        .font(.headline)
                    StatusBadgeView(status: appState.serviceManager.status)
                }

                Text(appState.serviceManager.statusDetail)
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }

            Spacer()

            Button {
                appState.handlePrimaryAction()
            } label: {
                HStack(spacing: 6) {
                    if appState.serviceManager.status == .starting {
                        ProgressView()
                            .controlSize(.small)
                    }
                    Text(primaryActionTitle)
                        .fontWeight(.semibold)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
            }
            .buttonStyle(.borderedProminent)
            .tint(buttonTintColor)
            .disabled(!appState.serviceManager.status.isActionEnabled)
        }
        .padding(18)
        .background(Color(NSColor.controlBackgroundColor))
        .cornerRadius(12)
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color(NSColor.separatorColor), lineWidth: 0.5)
        )
    }

    private var buttonTintColor: Color {
        switch appState.serviceManager.status {
        case .running:
            return .red
        case .uninstalled:
            return .orange
        case .error:
            return .blue
        default:
            return .accentColor
        }
    }

    private var primaryActionTitle: String {
        if appState.serviceManager.status == .running,
           appState.serviceManager.isExternallyManaged {
            return "重新检测"
        }
        return appState.serviceManager.status.primaryActionTitle
    }

    private func specItem(title: String, value: String, subvalue: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.caption)
                .foregroundColor(.secondary)
            Text(value)
                .font(.system(.subheadline, weight: .medium))
            Text(subvalue)
                .font(.caption2)
                .foregroundColor(.secondary)
        }
    }
}
