#if canImport(LovortPlayerCore)
import LovortPlayerCore
#endif
import SwiftUI

public struct LANMacSubtitleSettingsView: View {
    @State private var address = LANMacSubtitleSettings.address
    @State private var token = LANMacSubtitleSettings.accessToken
    @State private var status = ""
    @State private var testing = false

    public init() {}

    public var body: some View {
        Form {
            Section("Mac 服务") {
                TextField("192.168.1.20:8765", text: $address)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                SecureField("访问口令", text: $token)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Button {
                    LANMacSubtitleSettings.address = address
                    LANMacSubtitleSettings.accessToken = token
                    testing = true
                    status = "正在连接…"
                    Task {
                        defer { testing = false }
                        do { status = try await LANMacSubtitleService().testConnection() }
                        catch { status = error.localizedDescription }
                    }
                } label: {
                    if testing { ProgressView() }
                    else { Label("测试连接并保存", systemImage: "network") }
                }
                .disabled(testing || address.isEmpty || token.isEmpty)
                if !status.isEmpty { Text(status).font(.footnote) }
            }
            Section {
                Text("在 Mac 上启动字幕服务后，填写其局域网 IP 和启动时显示的口令。选择“局域网 Mac 转写”后，仅上传当前选中的音轨分片；原文和译文仍保存在手机。")
                Text("当前连接使用局域网 HTTP，请仅在可信的家庭网络中使用。私密视频不能发送到 Mac。")
            }
        }
        .navigationTitle("局域网 Mac 字幕服务")
        .onDisappear {
            LANMacSubtitleSettings.address = address
            LANMacSubtitleSettings.accessToken = token
        }
    }
}
