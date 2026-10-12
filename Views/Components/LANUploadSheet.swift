import SwiftUI

public struct LANUploadSheet: View {
    @State private var isServerRunning: Bool = false
    @State private var ipAddress: String = "正在检测局域网..."
    @State private var serverPort: UInt16 = 8080
    @State private var receivedFilesCount: Int = 0
    @State private var latestFileName: String? = nil
    @Environment(\.dismiss) private var dismiss

    public init() {}

    public var body: some View {
        NavigationStack {
            ZStack {
                Color(red: 0.04, green: 0.04, blue: 0.05).ignoresSafeArea()

                VStack(spacing: 24) {
                    // 状态图标
                    ZStack {
                        Circle()
                            .fill(Color.cyan.opacity(0.12))
                            .frame(width: 80, height: 80)
                        Image(systemName: "wifi")
                            .font(.system(size: 34, weight: .semibold))
                            .foregroundColor(.cyan)
                    }
                    .padding(.top, 20)

                    VStack(spacing: 8) {
                        Text("局域网免数据线直传")
                            .font(.system(size: 20, weight: .bold))
                            .foregroundColor(.white)
                        Text("手机与电脑连接同一 Wi-Fi，电脑浏览器访问下方地址即可拖拽传视频")
                            .font(.system(size: 13))
                            .foregroundColor(.white.opacity(0.6))
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 24)
                    }

                    // 访问地址卡片
                    VStack(spacing: 12) {
                        Text("电脑访问网址")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(.white.opacity(0.4))

                        Text("http://\(ipAddress):\(serverPort)")
                            .font(.system(size: 20, weight: .bold, design: .monospaced))
                            .foregroundColor(.cyan)
                            .textSelection(.enabled)

                        Text("已支持电脑拖拽，传输完毕后手机将自动落盘入库")
                            .font(.system(size: 11))
                            .foregroundColor(.white.opacity(0.4))
                    }
                    .padding(.vertical, 18)
                    .frame(maxWidth: .infinity)
                    .background(
                        RoundedRectangle(cornerRadius: 18)
                            .fill(Color.white.opacity(0.05))
                            .overlay(
                                RoundedRectangle(cornerRadius: 18)
                                    .stroke(Color.white.opacity(0.08), lineWidth: 1)
                            )
                    )
                    .padding(.horizontal, 20)

                    // 实时接收状态卡片
                    if let latest = latestFileName {
                        HStack(spacing: 12) {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundColor(.green)
                                .font(.system(size: 18))

                            VStack(alignment: .leading, spacing: 2) {
                                Text("刚收到新视频")
                                    .font(.system(size: 11))
                                    .foregroundColor(.white.opacity(0.5))
                                Text(latest)
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundColor(.white)
                                    .lineLimit(1)
                            }
                            Spacer()
                        }
                        .padding(14)
                        .background(
                            RoundedRectangle(cornerRadius: 14)
                                .fill(Color.green.opacity(0.12))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 14)
                                        .stroke(Color.green.opacity(0.2), lineWidth: 1)
                                )
                        )
                        .padding(.horizontal, 20)
                        .transition(.scale.combined(with: .opacity))
                    }

                    // 启停按钮
                    Button(action: toggleServer) {
                        HStack(spacing: 8) {
                            Circle()
                                .fill(isServerRunning ? Color.green : Color.red)
                                .frame(width: 8, height: 8)
                            Text(isServerRunning ? "传输服务运行中 (点击停止)" : "启动传输服务")
                                .font(.system(size: 14, weight: .semibold))
                        }
                        .foregroundColor(.white)
                        .padding(.horizontal, 24)
                        .padding(.vertical, 12)
                        .background(
                            Capsule()
                                .fill(Color.white.opacity(0.1))
                        )
                    }

                    Spacer()
                }
            }
            .navigationTitle("无线快传")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("完成") {
                        dismiss()
                    }
                    .foregroundColor(.white.opacity(0.8))
                }
            }
        }
        .onAppear {
            startService()
            LANServerManager.shared.onFileReceived = { [self] url, name in
                Task { @MainActor in
                    withAnimation {
                        self.receivedFilesCount += 1
                        self.latestFileName = name
                    }
                }
            }
        }
    }

    private func startService() {
        if let ip = LANServerManager.shared.getLocalIPAddress() {
            self.ipAddress = ip
        } else {
            self.ipAddress = "127.0.0.1"
        }
        try? LANServerManager.shared.startServer(port: 8080)
        self.isServerRunning = LANServerManager.shared.isRunning
    }

    private func toggleServer() {
        if isServerRunning {
            LANServerManager.shared.stopServer()
            isServerRunning = false
        } else {
            try? LANServerManager.shared.startServer(port: 8080)
            isServerRunning = LANServerManager.shared.isRunning
        }
    }
}
