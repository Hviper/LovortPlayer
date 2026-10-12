import SwiftUI

public struct AISubtitleSettingsSheet: View {
    @ObservedObject var viewModel: PlayerViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var selectedSourceLanguage: String = "自动检测"
    @State private var selectedTargetLanguage: String = "中文 (简体)"
    @State private var selectedEngine: String = "本地 Whisper 模型"

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
                                Text("自动识别视频中语音，生成双语对照字幕")
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

                        // 立即生成按钮
                        Button(action: {
                            viewModel.generateAISubtitles()
                        }) {
                            HStack {
                                if viewModel.isGeneratingSubtitles {
                                    ProgressView()
                                        .tint(.black)
                                        .padding(.trailing, 4)
                                    Text("正在抽取音频并生成字幕...")
                                        .font(.system(size: 14, weight: .semibold))
                                } else {
                                    Image(systemName: "sparkles")
                                    Text(viewModel.subtitles.isEmpty ? "立即提取并生成双语字幕" : "重新生成字幕 (\(viewModel.subtitles.count) 句已加载)")
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

                        // 语言配置卡片
                        VStack(alignment: .leading, spacing: 14) {
                            Text("语言偏好")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundColor(.white.opacity(0.4))

                            HStack {
                                Text("识别源语言")
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

                        // 引擎选择
                        VStack(alignment: .leading, spacing: 14) {
                            Text("驱动引擎")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundColor(.white.opacity(0.4))

                            Picker("驱动引擎", selection: $selectedEngine) {
                                Text("WhisperKit (本地零网络)").tag("本地 Whisper 模型")
                                Text("OpenAI / Cloud").tag("OpenAI / Cloud")
                            }
                            .pickerStyle(.segmented)
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
            .navigationTitle("AI 字幕配置")
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
    }
}
