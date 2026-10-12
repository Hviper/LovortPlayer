import SwiftUI

public struct AISubtitleSettingsSheet: View {
    @ObservedObject var viewModel: PlayerViewModel
    @StateObject private var authManager = AuthManager.shared
    @Environment(\.dismiss) private var dismiss

    @State private var apiKey: String = ""
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

                            Text(viewModel.subtitles.isEmpty ? "💡 提示：点击后将分析视频音频并生成带时间轴的对应双语字幕，返回播放即可看到画面字幕。" : "✅ 字幕已装载，继续播放视频，画面下方会自动随进度高亮当前句。")
                                .font(.system(size: 11))
                                .foregroundColor(.white.opacity(0.45))
                                .padding(.horizontal, 4)
                        }

                        // 账户与 AI 额度解锁 (ChatGPT / Antigravity OAuth 登录)
                        VStack(alignment: .leading, spacing: 14) {
                            Text("AI 额度与账号授权")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundColor(.white.opacity(0.5))

                            if let profile = authManager.currentProfile, profile.isLoggedIn {
                                HStack {
                                    VStack(alignment: .leading, spacing: 4) {
                                        HStack(spacing: 6) {
                                            Circle().fill(Color.green).frame(width: 8, height: 8)
                                            Text(profile.username)
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
                                    Button(action: { login(provider: .chatgpt) }) {
                                        HStack {
                                            Image(systemName: "person.badge.key.fill")
                                            Text("登录 ChatGPT 账号 (解锁 Whisper 额度)")
                                                .font(.system(size: 13, weight: .semibold))
                                        }
                                        .foregroundColor(.white)
                                        .frame(maxWidth: .infinity)
                                        .padding(.vertical, 11)
                                        .background(RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(0.1)))
                                    }

                                    Button(action: { login(provider: .antigravity) }) {
                                        HStack {
                                            Image(systemName: "bolt.shield.fill")
                                            Text("登录 Antigravity 账号 (解锁极速云端翻译)")
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

                        // 手动 API Key (备用方式)
                        VStack(alignment: .leading, spacing: 10) {
                            Text("或使用自备 API Key")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundColor(.white.opacity(0.5))

                            SecureField("sk-... (OpenAI API Key)", text: $apiKey)
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
            }
        }
    }

    private func login(provider: AuthProvider) {
        Task {
            isLoggingIn = true
            let ok = await authManager.loginWithProvider(provider)
            isLoggingIn = false
            if ok {
                withAnimation {
                    loginMessage = "登录成功，已关联 \(provider == .chatgpt ? "ChatGPT" : "Antigravity") 专属额度！"
                }
            }
        }
    }
}
