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
                        // 1. 账号授权与当前额度（排在首要位置清晰呈现）
                        VStack(alignment: .leading, spacing: 14) {
                            HStack {
                                Text("ChatGPT 订阅与 AI 额度")
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundColor(.white.opacity(0.6))
                                Spacer()
                                if let profile = authManager.currentProfile, profile.isLoggedIn {
                                    HStack(spacing: 4) {
                                        Circle().fill(Color.green).frame(width: 7, height: 7)
                                        Text("已认证")
                                            .font(.system(size: 11, weight: .medium))
                                            .foregroundColor(.green)
                                    }
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 3)
                                    .background(Capsule().fill(Color.green.opacity(0.12)))
                                }
                            }

                            if let profile = authManager.currentProfile, profile.isLoggedIn {
                                VStack(alignment: .leading, spacing: 10) {
                                    HStack {
                                        VStack(alignment: .leading, spacing: 3) {
                                            Text(profile.email)
                                                .font(.system(size: 15, weight: .bold))
                                                .foregroundColor(.white)
                                            Text("ChatGPT Plus / Pro 订阅会员")
                                                .font(.system(size: 12))
                                                .foregroundColor(AppSettings.shared.themeColor.color)
                                        }
                                        Spacer()
                                        Button(action: { authManager.logout() }) {
                                            Text("退出登录")
                                                .font(.system(size: 12, weight: .medium))
                                                .foregroundColor(.white.opacity(0.6))
                                                .padding(.horizontal, 10)
                                                .padding(.vertical, 5)
                                                .background(Capsule().fill(Color.white.opacity(0.08)))
                                        }
                                    }

                                    Divider().background(Color.white.opacity(0.08))

                                    VStack(alignment: .leading, spacing: 4) {
                                        HStack(spacing: 6) {
                                            Image(systemName: "checkmark.shield.fill")
                                                .font(.system(size: 11))
                                                .foregroundColor(.green)
                                            Text("当前额度：已绑定 GPT-4o / Codex 高速大模型通道")
                                                .font(.system(size: 12))
                                                .foregroundColor(.white.opacity(0.85))
                                        }
                                        HStack(spacing: 6) {
                                            Image(systemName: "bolt.fill")
                                                .font(.system(size: 11))
                                                .foregroundColor(.yellow)
                                            Text("离线赋能：支持为任意本地无字幕长视频离线批量预生成字幕")
                                                .font(.system(size: 11))
                                                .foregroundColor(.white.opacity(0.55))
                                        }
                                    }
                                }
                            } else {
                                VStack(spacing: 12) {
                                    Text("登录您的 ChatGPT 订阅账户即可借助 GPT-4o 大模型能力为本地无字幕视频一键预生成高精度双语字幕。")
                                        .font(.system(size: 12))
                                        .foregroundColor(.white.opacity(0.6))
                                        .fixedSize(horizontal: false, vertical: true)

                                    Button(action: { startSystemWebLogin(provider: .chatgpt) }) {
                                        HStack {
                                            if isLoggingIn {
                                                ProgressView().tint(.white).padding(.trailing, 4)
                                            } else {
                                                Image(systemName: "safari.fill")
                                            }
                                            Text("通过系统 Safari 登录 ChatGPT 订阅")
                                                .font(.system(size: 13, weight: .semibold))
                                        }
                                        .foregroundColor(.white)
                                        .frame(maxWidth: .infinity)
                                        .padding(.vertical, 12)
                                        .background(RoundedRectangle(cornerRadius: 12).fill(Color.white.opacity(0.12)))
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

                        // 2. 核心操作：离线先借助大模型为该视频生成字幕
                        VStack(alignment: .leading, spacing: 14) {
                            Text("视频字幕离线预生成")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundColor(.white.opacity(0.6))

                            Text("💡 区别于卡顿的边播边显示，点击下方按钮将提前抽取完整音轨，借助大模型能力智能生成完整双语时间轴字幕并永久保存在本地。生成后观影即开即显，零等待、零卡顿、无需实时联网！")
                                .font(.system(size: 12))
                                .foregroundColor(.white.opacity(0.6))
                                .fixedSize(horizontal: false, vertical: true)

                            // 语言选择
                            HStack(spacing: 12) {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("原声音频语言")
                                        .font(.system(size: 11))
                                        .foregroundColor(.white.opacity(0.45))
                                    Menu(selectedSourceLanguage) {
                                        Button("自动检测") { selectedSourceLanguage = "自动检测" }
                                        Button("英语 (English)") { selectedSourceLanguage = "英语 (English)" }
                                        Button("日语 (日本語)") { selectedSourceLanguage = "日语 (日本語)" }
                                        Button("中文 (普通话)") { selectedSourceLanguage = "中文 (普通话)" }
                                        Button("韩语 (한국어)") { selectedSourceLanguage = "韩语 (한국어)" }
                                    }
                                    .font(.system(size: 13, weight: .medium))
                                    .foregroundColor(AppSettings.shared.themeColor.color)
                                }
                                .padding(10)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(0.05)))

                                VStack(alignment: .leading, spacing: 4) {
                                    Text("翻译目标语言")
                                        .font(.system(size: 11))
                                        .foregroundColor(.white.opacity(0.45))
                                    Menu(selectedTargetLanguage) {
                                        Button("中文 (简体)") { selectedTargetLanguage = "中文 (简体)" }
                                        Button("中文 (繁體)") { selectedTargetLanguage = "中文 (繁體)" }
                                        Button("英语 (English)") { selectedTargetLanguage = "英语 (English)" }
                                    }
                                    .font(.system(size: 13, weight: .medium))
                                    .foregroundColor(AppSettings.shared.themeColor.color)
                                }
                                .padding(10)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(0.05)))
                            }

                            // 预生成按钮
                            Button(action: {
                                viewModel.generateAISubtitles(
                                    sourceLanguage: selectedSourceLanguage,
                                    targetLanguage: selectedTargetLanguage
                                )
                            }) {
                                HStack(spacing: 8) {
                                    if viewModel.isGeneratingSubtitles {
                                        ProgressView()
                                            .tint(.white)
                                        Text(viewModel.generatingSubtitleStatusText.isEmpty ? "正在离线处理音频并生成字幕..." : viewModel.generatingSubtitleStatusText)
                                            .font(.system(size: 14, weight: .semibold))
                                            .lineLimit(1)
                                    } else if !viewModel.subtitles.isEmpty {
                                        Image(systemName: "checkmark.seal.fill")
                                            .foregroundColor(.green)
                                        Text("✅ 离线字幕已就绪 (共 \(viewModel.subtitles.count) 句) · 点击重新生成")
                                            .font(.system(size: 14, weight: .semibold))
                                    } else {
                                        Image(systemName: "sparkles")
                                        Text("一键为该视频生成离线 AI 双语字幕")
                                            .font(.system(size: 14, weight: .semibold))
                                    }
                                }
                                .foregroundColor(.white)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 14)
                                .background(
                                    RoundedRectangle(cornerRadius: 14)
                                        .fill(viewModel.subtitles.isEmpty ? AppSettings.shared.themeColor.color : Color.white.opacity(0.12))
                                )
                                .overlay(
                                    RoundedRectangle(cornerRadius: 14)
                                        .stroke(!viewModel.subtitles.isEmpty ? Color.green.opacity(0.5) : Color.clear, lineWidth: 1)
                                )
                            }
                            .disabled(viewModel.isGeneratingSubtitles)

                            if let errorMsg = viewModel.subtitleErrorMessage {
                                HStack(spacing: 6) {
                                    Image(systemName: "exclamationmark.triangle.fill")
                                        .foregroundColor(.red)
                                    Text("生成未完成: \(errorMsg)")
                                        .font(.system(size: 12))
                                        .foregroundColor(.red.opacity(0.9))
                                }
                                .padding(10)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(RoundedRectangle(cornerRadius: 10).fill(Color.red.opacity(0.12)))
                            }
                        }
                        .padding(16)
                        .background(
                            RoundedRectangle(cornerRadius: 16)
                                .fill(Color.white.opacity(0.06))
                        )

                        // 3. 字幕画面显示总开关
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("画面字幕浮层跟随显示")
                                    .font(.system(size: 15, weight: .semibold))
                                    .foregroundColor(.white)
                                Text("开启后，播放视频时画面底部将跟随时间轴显示双语字幕")
                                    .font(.system(size: 12))
                                    .foregroundColor(.white.opacity(0.5))
                            }
                            Spacer()
                            Toggle("", isOn: $viewModel.isAISubtitleEnabled)
                                .labelsHidden()
                                .tint(AppSettings.shared.themeColor.color)
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
