import SwiftUI
import LovortPlayerCore

public struct LANUploadSheet: View {
    @State private var isServerRunning: Bool = false
    @State private var ipAddress: String = "正在检测局域网..."
    @State private var serverPort: UInt16 = 8080
    @Environment(\.dismiss) private var dismiss

    public init() {}

    public var body: some View {
        NavigationStack {
            ZStack {
                Color(red: 0.04, green: 0.04, blue: 0.05).ignoresSafeArea()

                VStack(spacing: 28) {
                    // 状态图标
                    ZStack {
                        Circle()
                            .fill(Color.cyan.opacity(0.12))
                            .frame(width: 90, height: 90)
                        Image(systemName: "wifi")
                            .font(.system(size: 38, weight: .semibold))
                            .foregroundColor(.cyan)
                    }
                    .padding(.top, 24)

                    VStack(spacing: 8) {
                        Text("局域网免数据线直传")
                            .font(.system(size: 20, weight: .bold))
                            .foregroundColor(.white)
                        Text("在同一 Wi-Fi 下，电脑浏览器访问下方地址即可拖拽传视频")
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

                        Text("支持 MKV, MP4, MOV, AVI 多格式")
                            .font(.system(size: 11))
                            .foregroundColor(.white.opacity(0.4))
                    }
                    .padding(.vertical, 20)
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
