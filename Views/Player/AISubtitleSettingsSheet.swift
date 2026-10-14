import SwiftUI
#if canImport(LovortPlayerCore)
import LovortPlayerCore
#endif

@MainActor
private final class SubtitlePreviewController: ObservableObject {
    @Published var isRunning = false
    @Published var status = ""
    @Published var result: SubtitlePreviewResult?
    @Published var errorMessage: String?
    private var task: Task<Void, Never>?
    private var runID = UUID()

    func start(videoURL: URL, startTime: TimeInterval, language: SubtitleSourceLanguage,
               model: OfflineWhisperModel, provider: SubtitleTranslationProviderType,
               targetLanguage: String) {
        task?.cancel()
        let currentRun = UUID()
        runID = currentRun
        result = nil
        errorMessage = nil
        status = "正在准备 30 秒预览…"
        isRunning = true
        task = Task { [weak self] in
            guard let self else { return }
            defer {
                if self.runID == currentRun {
                    self.isRunning = false
                    self.task = nil
                }
            }
            do {
                let result = try await AISubtitleCoordinator.shared.previewLocalVideo(
                    videoURL: videoURL, startTime: startTime,
                    sourceLanguage: language, model: model,
                    translationProvider: provider, targetLanguage: targetLanguage,
                    onProgress: { [weak self] message in
                        Task { @MainActor in
                            guard let self, self.runID == currentRun, self.isRunning else { return }
                            self.status = message
                        }
                    }
                )
                guard self.runID == currentRun, !Task.isCancelled else { return }
                self.result = result
                self.status = "预览完成"
            } catch is CancellationError {
                if self.runID == currentRun { self.status = "预览已取消" }
            } catch {
                guard self.runID == currentRun else { return }
                self.errorMessage = error.localizedDescription
                self.status = "预览失败"
            }
        }
    }

    func cancel() {
        runID = UUID()
        task?.cancel()
        task = nil
        isRunning = false
        status = "预览已取消"
    }
}

public struct AISubtitleSettingsSheet: View {
    @ObservedObject var viewModel: PlayerViewModel
    @ObservedObject private var modelManager = AIModelManager.shared
    @Environment(\.dismiss) private var dismiss

    @State private var apiKey: String = ""
    @State private var proxyHost: String = ""
    @State private var proxyPort: String = ""
    @State private var selectedSourceLanguage: SubtitleSourceLanguage = .japanese
    @State private var selectedTargetLanguage: String = "中文 (简体)"
    @State private var selectedEngine: AISubtitleEngineType = AISubtitleCoordinator.shared.currentEngine
    @State private var selectedOfflineModel: OfflineWhisperModel = AISubtitleCoordinator.shared.offlineModel
    @State private var selectedTranslationProvider: SubtitleTranslationProviderType = AISubtitleCoordinator.shared.translationProvider
    @State private var enhanceWithGPT: Bool = AISubtitleCoordinator.shared.isGPTEnhancementEnabled
    @State private var translationAPIKey: String = ""
    @State private var azureRegion: String = ""
    @State private var communityMatchStatus: String = ""
    @State private var showCustomModelSheet: Bool = false
    @State private var customModelText: String = ""
    @StateObject private var preview = SubtitlePreviewController()

    public init(viewModel: PlayerViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        NavigationStack {
            ZStack {
                Color(red: 0.04, green: 0.04, blue: 0.05).ignoresSafeArea()

                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        translationProviderSection
                        if selectedTranslationProvider == .openAI {
                            modelSelectionSection
                        } else if enhanceWithGPT {
                            modelSelectionSection
                        }
                        offlineGenerationSection
                        displayToggleSection
                        proxySettingsSection
                        if selectedTranslationProvider == .openAI || selectedEngine == .cloudOpenAI || enhanceWithGPT {
                            manualApiKeySection
                        }
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
            .alert("手动输入大模型名称", isPresented: $showCustomModelSheet) {
                TextField("如: gpt-6.1-sol, gpt-6-astra, gpt-6-luna", text: $customModelText)
                Button("确定切换") {
                    let trimmed = customModelText.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty {
                        modelManager.selectModel(trimmed)
                    }
                }
                Button("取消", role: .cancel) {}
            } message: {
                Text("输入 OpenAI Platform 项目可用的模型 ID，设定后用于影视字幕翻译或语境精修。")
            }
            .onAppear {
                self.selectedTranslationProvider = AISubtitleCoordinator.shared.translationProvider
                self.apiKey = AISubtitleCoordinator.shared.getSavedOpenAIKey()
                self.proxyHost = UserDefaults.standard.string(forKey: "LovortCustomProxyHost") ?? ""
                let port = UserDefaults.standard.integer(forKey: "LovortCustomProxyPort")
                self.proxyPort = port > 0 ? String(port) : ""

                if self.apiKey.hasPrefix("sk-") {
                    Task {
                        await modelManager.fetchAvailableModels(token: self.apiKey)
                    }
                }
                self.translationAPIKey = TranslationCredentialStore.shared.value(for: selectedTranslationProvider)
                self.azureRegion = UserDefaults.standard.string(forKey: "LovortAzureTranslatorRegion") ?? ""
            }
            .onDisappear { preview.cancel() }
        }
    }

    // MARK: - 1. 当前大模型 (可自由切换)
    private var modelSelectionSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("当前大模型 (可自由切换)")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.white.opacity(0.6))
                Spacer()
                if modelManager.isFetchingModels {
                    ProgressView()
                        .scaleEffect(0.7)
                        .tint(.white.opacity(0.7))
                } else {
                    Button(action: {
                        Task {
                            await modelManager.fetchAvailableModels(token: apiKey)
                        }
                    }) {
                        HStack(spacing: 4) {
                            Image(systemName: "arrow.triangle.2.circlepath")
                                .font(.system(size: 11))
                            Text("刷新模型")
                                .font(.system(size: 11, weight: .medium))
                        }
                        .foregroundColor(AppSettings.shared.themeColor.color)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Capsule().fill(AppSettings.shared.themeColor.color.opacity(0.12)))
                    }
                }
            }

            // 当前选中模型展示 & 切换菜单
            Menu {
                ForEach(modelManager.availableModels) { model in
                    Button(action: {
                        modelManager.selectModel(model.id)
                    }) {
                        HStack {
                            Text(model.displayName)
                            if let badge = model.badge {
                                Text(" [\(badge)]")
                            }
                            if modelManager.selectedModelID == model.id {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }

                Divider()

                Button(action: {
                    customModelText = modelManager.selectedModelID
                    showCustomModelSheet = true
                }) {
                    Label("手动输入其它可用模型...", systemImage: "pencil")
                }
            } label: {
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            Text(modelManager.currentModelInfo.displayName)
                                .font(.system(size: 15, weight: .bold))
                                .foregroundColor(.white)
                            if let badge = modelManager.currentModelInfo.badge {
                                Text(badge)
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundColor(AppSettings.shared.themeColor.color)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(Capsule().fill(AppSettings.shared.themeColor.color.opacity(0.15)))
                            }
                        }
                        Text(modelManager.currentModelInfo.description)
                            .font(.system(size: 11))
                            .foregroundColor(.white.opacity(0.55))
                            .lineLimit(2)
                    }
                    Spacer()
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(AppSettings.shared.themeColor.color)
                }
                .padding(12)
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Color.white.opacity(0.05))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(AppSettings.shared.themeColor.color.opacity(0.35), lineWidth: 1)
                )
            }

            TranslationConnectionTestView(configuration: TranslationConnectionConfiguration(
                settings: TranslationAPISettings(provider: .openAI), apiKey: apiKey,
                openAIModel: modelManager.selectedModelID))

            if let msg = modelManager.fetchMessage {
                Text(msg)
                    .font(.system(size: 11))
                    .foregroundColor(.green.opacity(0.9))
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(Color.white.opacity(0.06))
        )
    }

    // MARK: - 2. 视频字幕获取（社区精校匹配 + AI 离线生成）
    private var offlineGenerationSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("字幕获取与智能生成")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.white.opacity(0.6))

            Text("💡 WhisperKit 会优先处理当前播放位置附近的音频。每个分片识别完成后即可显示原文，全部识别完后再翻译。模型首次使用需联网下载，之后可离线转写。")
                .font(.system(size: 12))
                .foregroundColor(.white.opacity(0.6))
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 6) {
                Text("转写方式")
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.45))
                Picker("转写方式", selection: $selectedEngine) {
                    Text(AISubtitleEngineType.localWhisperKit.displayName)
                        .tag(AISubtitleEngineType.localWhisperKit)
                    Text(AISubtitleEngineType.cloudOpenAI.displayName)
                        .tag(AISubtitleEngineType.cloudOpenAI)
                }
                .pickerStyle(.segmented)
            }

            if selectedEngine == .localWhisperKit {
                VStack(alignment: .leading, spacing: 6) {
                    Text("离线模型")
                        .font(.system(size: 11))
                        .foregroundColor(.white.opacity(0.45))
                    Menu {
                        ForEach(OfflineWhisperModel.allCases) { model in
                            Button {
                                selectedOfflineModel = model
                            } label: {
                                if selectedOfflineModel == model {
                                    Label(model.displayName, systemImage: "checkmark")
                                } else {
                                    Text(model.displayName)
                                }
                            }
                        }
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(selectedOfflineModel.displayName)
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundColor(.white)
                                Text(selectedOfflineModel.detail)
                                    .font(.system(size: 10))
                                    .foregroundColor(.white.opacity(0.48))
                            }
                            Spacer()
                            Image(systemName: "chevron.up.chevron.down")
                                .foregroundColor(AppSettings.shared.themeColor.color)
                        }
                        .padding(10)
                        .background(RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(0.05)))
                    }
                }
            } else {
                Text("云端转写会按 4 分钟自动切片，避免 OpenAI 单文件 25 MB 限制；必须填写 Platform API Key。")
                    .font(.system(size: 10))
                    .foregroundColor(.orange.opacity(0.8))
            }

            // 语言选择
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("原声音频语言")
                        .font(.system(size: 11))
                        .foregroundColor(.white.opacity(0.45))
                    Menu(selectedSourceLanguage.displayName) {
                        ForEach(SubtitleSourceLanguage.allCases) { language in
                            Button(language.displayName) { selectedSourceLanguage = language }
                        }
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

            VStack(spacing: 10) {
                if selectedEngine == .localWhisperKit {
                    VStack(alignment: .leading, spacing: 9) {
                        Button {
                            if preview.isRunning {
                                preview.cancel()
                                return
                            }
                            guard let videoURL = viewModel.currentVideoURL else { return }
                            preview.start(
                                videoURL: videoURL, startTime: viewModel.currentTime,
                                language: selectedSourceLanguage, model: selectedOfflineModel,
                                provider: selectedTranslationProvider,
                                targetLanguage: selectedTargetLanguage
                            )
                        } label: {
                            HStack {
                                if preview.isRunning { ProgressView().tint(.white) }
                                Label(preview.isRunning ? "取消预览" : "预览当前播放位置附近 30 秒字幕",
                                      systemImage: preview.isRunning ? "xmark.circle" : "text.bubble")
                            }
                            .font(.system(size: 13, weight: .semibold))
                            .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        .disabled(viewModel.isGeneratingSubtitles && !preview.isRunning)
                        if !preview.status.isEmpty {
                            Text(preview.status)
                                .font(.system(size: 11))
                                .foregroundColor(.white.opacity(0.65))
                        }
                        if let error = preview.errorMessage {
                            Text(error).font(.system(size: 11)).foregroundColor(.orange)
                        }
                        if let result = preview.result {
                            Text("预览区间：\(Int(result.startTime))–\(Int(result.endTime)) 秒 · \(result.audioTrackDescription) · \(result.lines.count) 句")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundColor(.white.opacity(0.7))
                            Text("预览耗时 \(Int(result.elapsedTime.rounded())) 秒（含模型加载和翻译）")
                                .font(.system(size: 11))
                                .foregroundColor(.white.opacity(0.6))
                            if let warning = result.translationWarning {
                                Text(warning).font(.system(size: 11)).foregroundColor(.orange)
                            }
                            ForEach(result.lines.prefix(8)) { line in
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(line.originalText).foregroundColor(.white)
                                    if let translated = line.translatedText {
                                        Text(translated).foregroundColor(.cyan)
                                    }
                                }
                                .font(.system(size: 12))
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                    }
                    .padding(12)
                    .background(RoundedRectangle(cornerRadius: 12).fill(Color.white.opacity(0.05)))
                }

                // 社区精校字幕 (射手网 / 字幕组) 一键匹配
                Button(action: {
                    Task {
                        await fetchCommunitySubtitles()
                    }
                }) {
                    HStack(spacing: 8) {
                        Image(systemName: "globe.asia.australia.fill")
                        Text(communityMatchStatus.isEmpty ? "检索社区字幕组精校字幕 (射手网免额度)" : communityMatchStatus)
                            .font(.system(size: 13, weight: .semibold))
                            .lineLimit(1)
                    }
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 13)
                    .background(RoundedRectangle(cornerRadius: 14).fill(Color.purple.opacity(0.45)))
                    .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.purple.opacity(0.8), lineWidth: 1))
                }

                // AI 大模型智能生成按钮
                Button(action: {
                    viewModel.generateAISubtitles(
                        sourceLanguage: selectedSourceLanguage,
                        targetLanguage: selectedTargetLanguage,
                        engine: selectedEngine,
                        offlineModel: selectedOfflineModel,
                        translationProvider: selectedTranslationProvider,
                        enhanceWithGPT: enhanceWithGPT
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
                            Text("✅ 字幕已就绪 (共 \(viewModel.subtitles.count) 句)")
                                .font(.system(size: 14, weight: .semibold))
                        } else {
                            Image(systemName: "sparkles")
                            Text(selectedEngine == .localWhisperKit ? "离线生成原文并翻译为双语字幕" : "云端生成并翻译为双语字幕")
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
            }

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
    }

    private var translationProviderSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("中文字幕翻译方式")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.white.opacity(0.6))

            Menu {
                ForEach(SubtitleTranslationProviderType.allCases) { provider in
                    Button {
                        selectedTranslationProvider = provider
                        AISubtitleCoordinator.shared.translationProvider = provider
                        translationAPIKey = TranslationCredentialStore.shared.value(for: provider)
                    } label: {
                        if provider == selectedTranslationProvider {
                            Label(provider.displayName, systemImage: "checkmark")
                        } else {
                            Text(provider.displayName)
                        }
                    }
                }
            } label: {
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(selectedTranslationProvider.displayName)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(.white)
                        Text(selectedTranslationProvider.detail)
                            .font(.system(size: 11))
                            .foregroundColor(.white.opacity(0.5))
                    }
                    Spacer()
                    Image(systemName: "chevron.up.chevron.down")
                        .foregroundColor(AppSettings.shared.themeColor.color)
                }
                .padding(12)
                .background(RoundedRectangle(cornerRadius: 12).fill(Color.white.opacity(0.05)))
            }

            if selectedTranslationProvider == .apple {
                Label("语言包准备完成后，翻译在设备端进行，不上传字幕文本。", systemImage: "iphone.and.arrow.forward")
                    .font(.system(size: 11))
                    .foregroundColor(.green.opacity(0.85))
            } else if selectedTranslationProvider.usesChatCompletions || selectedTranslationProvider == .volcengineMachineTranslation {
                NavigationLink("管理翻译服务与凭证") {
                    TranslationAPIManagementView()
                }
                .foregroundColor(AppSettings.shared.themeColor.color)
            } else if selectedTranslationProvider.requiresAPIKey {
                SecureField("\(selectedTranslationProvider.displayName) API Key", text: $translationAPIKey)
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundColor(.white)
                    .padding(12)
                    .background(RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(0.08)))
                    .onChange(of: translationAPIKey) { value in
                        TranslationCredentialStore.shared.setValue(value, for: selectedTranslationProvider)
                    }
                if selectedTranslationProvider == .azure {
                    TextField("Azure 区域，例如 eastasia（全局资源可留空）", text: $azureRegion)
                        .font(.system(size: 13, design: .monospaced))
                        .foregroundColor(.white)
                        .padding(12)
                        .background(RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(0.08)))
                        .onChange(of: azureRegion) { value in
                            UserDefaults.standard.set(value.trimmingCharacters(in: .whitespacesAndNewlines), forKey: "LovortAzureTranslatorRegion")
                        }
                }
            } else {
                Text("需要 OpenAI Platform API Key。ChatGPT Plus/Pro 订阅与 API 额度分别计费，不能直接替代 API Key。")
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.5))
            }

            if selectedTranslationProvider != .openAI {
                Toggle(isOn: $enhanceWithGPT) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("生成后用 GPT 做影视语境精修")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(.white)
                        Text("可选：统一人物称谓、敬语、俚语和角色口吻；需要 OpenAI Platform API Key")
                            .font(.system(size: 10))
                            .foregroundColor(.white.opacity(0.45))
                    }
                }
                .tint(AppSettings.shared.themeColor.color)
                .onChange(of: enhanceWithGPT) { value in
                    AISubtitleCoordinator.shared.isGPTEnhancementEnabled = value
                }
            }
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 16).fill(Color.white.opacity(0.06)))
    }

    // MARK: - 3. 画面字幕浮层跟随显示
    private var displayToggleSection: some View {
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
    }

    // MARK: - 4. 网络代理设置
    private var proxySettingsSection: some View {
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
    }

    // MARK: - 5. 手动 API Key (备用方式)
    private var manualApiKeySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("OpenAI Platform API Key")
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(.white.opacity(0.5))

            SecureField("sk-...（用于 GPT 翻译/精修或云端转写）", text: $apiKey)
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

    private func saveProxy() {
        UserDefaults.standard.set(proxyHost.trimmingCharacters(in: .whitespaces), forKey: "LovortCustomProxyHost")
        if let p = Int(proxyPort.trimmingCharacters(in: .whitespaces)) {
            UserDefaults.standard.set(p, forKey: "LovortCustomProxyPort")
        } else {
            UserDefaults.standard.removeObject(forKey: "LovortCustomProxyPort")
        }
    }

    private func fetchCommunitySubtitles() async {
        guard let url = viewModel.currentVideoURL else {
            communityMatchStatus = "未找到视频源"
            return
        }
        communityMatchStatus = "正在检索社区精校字幕..."
        do {
            let results = try await ShooterSubtitleService.shared.fetchCommunitySubtitles(videoURL: url)
            if let best = results.first {
                communityMatchStatus = "找到：\(best.desc)，正在秒级装载..."
                let lines = try await ShooterSubtitleService.shared.downloadAndParseSubtitle(from: best.downloadURL)
                if !lines.isEmpty {
                    viewModel.subtitles = lines
                    viewModel.isAISubtitleEnabled = true
                    let targetSRT = url.deletingPathExtension().appendingPathExtension("srt")
                    try? SRTParser.generateSRT(from: lines).write(to: targetSRT, atomically: true, encoding: .utf8)
                    communityMatchStatus = "✅ 成功匹配社区字幕组精校字幕 (共 \(lines.count) 句)"
                } else {
                    communityMatchStatus = "未解析到台词，建议使用下方 AI 生成"
                }
            } else {
                communityMatchStatus = "社区库未收录该视频，请使用下方 AI 生成"
            }
        } catch {
            communityMatchStatus = "检索失败，请使用下方 AI 生成"
        }
        try? await Task.sleep(nanoseconds: 3_500_000_000)
        communityMatchStatus = ""
    }
}
