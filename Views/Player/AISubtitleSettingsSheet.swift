import SwiftUI

public struct AISubtitleSettingsSheet: View {
    @ObservedObject var viewModel: PlayerViewModel
    @StateObject private var authManager = AuthManager.shared
    @Environment(\.dismiss) private var dismiss

    @State private var apiKey: String = ""
    @State private var proxyHost: String = ""
    @State private var proxyPort: String = ""
    @State private var selectedSourceLanguage: String = "自动检测"
    @State private var selectedTargetLanguage: String = "中文 (简体)"
    @State private var isLoggingIn: Bool = false
    @State private var loginMessage: String? = nil

    public init(viewModel: PlayerViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        NavigationStack {
            ZStack {
                Color(red: 0.04, green: 0.04, blue: 0.05).ignoresSafeArea()

                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        // 开关卡片
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("AI 实时双语字幕")
                                    .font(.system(size: 16, weight: .semibold))
                                    .foregroundColor(.white)
                                Text("开启后，视频播放时画面底部将浮动显示双语字幕")
                                    .font(.system(size: 12))
                                    .foregroundColor(.white.opacity(0.5))
                            }
                            Spacer()
                            Toggle("", isOn: $viewModel.isAISubtitleEnabled)
                                .labelsHidden()
                                .tint(.cyan)
                        }
                        .padding(16)
                        .background(
                            RoundedRectangle(cornerRadius: 16)
                                .fill(Color.white.opacity(0.06))
                        )

                        // 核心操作：生成/重新提取当前视频字幕
                        VStack(alignment: .leading, spacing: 10) {
                            Button(action: {
                                viewModel.generateAISubtitles()
                            }) {
                                HStack {
                                    if viewModel.isGeneratingSubtitles {
                                        ProgressView()
                                            .tint(.black)
                                            .padding(.trailing, 4)
                                        Text("正在抽取音轨并生成字幕...")
                                            .font(.system(size: 14, weight: .semibold))
                                    } else {
                                        Image(systemName: "sparkles")
                                        Text(viewModel.subtitles.isEmpty ? "立即提取并生成双语字幕" : "重新生成字幕 (当前已就绪 \(viewModel.subtitles.count) 句)")
                                            .font(.system(size: 14, weight: .semibold))
                                    }
                                }
                                .foregroundColor(.black)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 14)
                                .background(
                                    RoundedRectangle(cornerRadius: 14)
                                        .fill(Color.cyan)
                                )
                            }
                            .disabled(viewModel.isGeneratingSubtitles)

                            Text(viewModel.subtitles.isEmpty ? "💡 提示：点击后将提取视频音轨调用 Whisper 转录与翻译，完成后直接返回视频即可看到画面下方字幕跟随播放。" : "✅ 字幕已装载，画面下方已同步显示中英双语字幕。")
                                .font(.system(size: 11))
                                .foregroundColor(.white.opacity(0.45))
                                .padding(.horizontal, 4)
                        }

                        // 真实账户授权 (通过系统 Safari 认证，支持系统 VPN / Clash 代理)
                        VStack(alignment: .leading, spacing: 14) {
                            Text("AI 额度与账号授权")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundColor(.white.opacity(0.5))

                            if let profile = authManager.currentProfile, profile.isLoggedIn {
                                HStack {
                                    VStack(alignment: .leading, spacing: 4) {
                                        HStack(spacing: 6) {
                                            Circle().fill(Color.green).frame(width: 8, height: 8)
                                            Text(profile.email)
                                                .font(.system(size: 14, weight: .semibold))
                                                .foregroundColor(.white)
                                        }
                                        Text("配额: \(profile.quotaRemaining)")
                                            .font(.system(size: 11))
                                            .foregroundColor(.cyan)
                                    }
                                    Spacer()
                                    Button(action: { authManager.logout() }) {
                                        Text("退出")
                                            .font(.system(size: 12))
                                            .foregroundColor(.white.opacity(0.6))
                                            .padding(.horizontal, 10)
                                            .padding(.vertical, 5)
                                            .background(Capsule().fill(Color.white.opacity(0.1)))
                                    }
                                }
                            } else {
                                VStack(spacing: 10) {
                                    Button(action: { startSystemWebLogin(provider: .chatgpt) }) {
                                        HStack {
                                            if isLoggingIn {
                                                ProgressView().tint(.white).padding(.trailing, 4)
                                            } else {
                                                Image(systemName: "safari.fill")
                                            }
                                            Text("通过系统 Safari 登录 ChatGPT")
                                                .font(.system(size: 13, weight: .semibold))
                                        }
                                        .foregroundColor(.white)
                                        .frame(maxWidth: .infinity)
                                        .padding(.vertical, 11)
                                        .background(RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(0.1)))
                                    }

                                    Button(action: { startSystemWebLogin(provider: .antigravity) }) {
                                        HStack {
                                            Image(systemName: "bolt.shield.fill")
                                            Text("通过系统 Safari 登录 GitHub / Antigravity")
                                                .font(.system(size: 13, weight: .semibold))
                                        }
                                        .foregroundColor(.cyan)
                                        .frame(maxWidth: .infinity)
                                        .padding(.vertical, 11)
                                        .background(RoundedRectangle(cornerRadius: 10).fill(Color.cyan.opacity(0.1)))
                                    }
                                }
                            }

                            if let msg = loginMessage {
                                Text(msg)
                                    .font(.system(size: 12))
                                    .foregroundColor(.green)
                            }
                        }
                        .padding(16)
                        .background(
                            RoundedRectangle(cornerRadius: 16)
                                .fill(Color.white.opacity(0.06))
                        )

                        // 代理与网络配置 (支持 Clash / 局域网 HTTP 代理)
                        VStack(alignment: .leading, spacing: 10) {
                            Text("网络代理设置 (Clash / 本地代理)")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundColor(.white.opacity(0.5))

                            HStack(spacing: 10) {
                                TextField("代理 IP (如 127.0.0.1)", text: $proxyHost)
                                    .font(.system(size: 13, design: .monospaced))
                                    .foregroundColor(.white)
                                    .padding(10)
                                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.08)))

                                TextField("端口 (如 7890)", text: $proxyPort)
                                    .font(.system(size: 13, design: .monospaced))
                                    .foregroundColor(.white)
                                    .frame(width: 90)
                                    .padding(10)
                                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.08)))
                            }
                            .onChange(of: proxyHost) { _ in saveProxy() }
                            .onChange(of: proxyPort) { _ in saveProxy() }

                            Text("若手机已开启 Shadowrocket / Clash 等 VPN 模式，留空即可直走系统代理。")
                                .font(.system(size: 10))
                                .foregroundColor(.white.opacity(0.4))
                        }
                        .padding(16)
                        .background(
                            RoundedRectangle(cornerRadius: 16)
                                .fill(Color.white.opacity(0.06))
                        )

                        // 手动 API Key (备用方式)
                        VStack(alignment: .leading, spacing: 10) {
                            Text("OpenAI API Key (可选)")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundColor(.white.opacity(0.5))

                            SecureField("sk-... (填写后调用真实 Whisper API)", text: $apiKey)
                                .font(.system(size: 13, design: .monospaced))
                                .foregroundColor(.white)
                                .padding(12)
                                .background(RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(0.08)))
                                .onChange(of: apiKey) { newValue in
                                    AISubtitleCoordinator.shared.saveOpenAIKey(newValue)
                                }
                        }
                        .padding(16)
                        .background(
                            RoundedRectangle(cornerRadius: 16)
                                .fill(Color.white.opacity(0.06))
                        )

                        // 语言偏好设置
                        VStack(alignment: .leading, spacing: 14) {
                            Text("语言设置")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundColor(.white.opacity(0.4))

                            HStack {
                                Text("原音源语言")
                                    .foregroundColor(.white.opacity(0.85))
                                Spacer()
                                Menu(selectedSourceLanguage) {
                                    Button("自动检测") { selectedSourceLanguage = "自动检测" }
                                    Button("英语 (English)") { selectedSourceLanguage = "英语 (English)" }
                                    Button("日语 (日本語)") { selectedSourceLanguage = "日语 (日本語)" }
                                    Button("韩语 (한국어)") { selectedSourceLanguage = "韩语 (한국어)" }
                                }
                                .foregroundColor(.cyan)
                            }

                            Divider().background(Color.white.opacity(0.1))

                            HStack {
                                Text("翻译目标语言")
                                    .foregroundColor(.white.opacity(0.85))
                                Spacer()
                                Menu(selectedTargetLanguage) {
                                    Button("中文 (简体)") { selectedTargetLanguage = "中文 (简体)" }
                                    Button("中文 (繁體)") { selectedTargetLanguage = "中文 (繁體)" }
                                    Button("英语 (English)") { selectedTargetLanguage = "英语 (English)" }
                                }
                                .foregroundColor(.cyan)
                            }
                        }
                        .padding(16)
                        .background(
                            RoundedRectangle(cornerRadius: 16)
                                .fill(Color.white.opacity(0.06))
                        )
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 24)
                }
            }
            .navigationTitle("AI 字幕选项")
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
            .onAppear {
                self.apiKey = AISubtitleCoordinator.shared.getSavedOpenAIKey()
                self.proxyHost = UserDefaults.standard.string(forKey: "LovortCustomProxyHost") ?? ""
                let port = UserDefaults.standard.integer(forKey: "LovortCustomProxyPort")
                self.proxyPort = port > 0 ? String(port) : ""
            }
        }
    }

    private func saveProxy() {
        UserDefaults.standard.set(proxyHost.trimmingCharacters(in: .whitespaces), forKey: "LovortCustomProxyHost")
        if let p = Int(proxyPort.trimmingCharacters(in: .whitespaces)) {
            UserDefaults.standard.set(p, forKey: "LovortCustomProxyPort")
        } else {
            UserDefaults.standard.removeObject(forKey: "LovortCustomProxyPort")
        }
    }

    private func startSystemWebLogin(provider: AuthProvider) {
        Task {
            isLoggingIn = true
            do {
                _ = try await authManager.startWebAuthLogin(provider: provider)
                withAnimation {
                    loginMessage = "已通过系统 Safari 认证！"
                }
            } catch {
                withAnimation {
                    loginMessage = "登录未完成: \(error.localizedDescription)"
                }
            }
            isLoggingIn = false
        }
    }
}
