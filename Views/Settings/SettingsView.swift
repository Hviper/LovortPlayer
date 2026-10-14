import SwiftUI
#if canImport(LovortPlayerCore)
import LovortPlayerCore
#endif

/// 完整的 Lovort 设置页面
public struct SettingsView: View {
    @ObservedObject private var settings = AppSettings.shared
    @Environment(\.dismiss) private var dismiss

    @State private var showResetConfirm = false
    @State private var showClearCacheConfirm = false
    @State private var isClearingCache = false
    @State private var showClearCacheDone = false

    public init() {}

    public var body: some View {
        NavigationStack {
            ZStack {
                Color(red: 0.04, green: 0.04, blue: 0.05).ignoresSafeArea()

                ScrollView {
                    VStack(spacing: 24) {
                        // 通用 - 主题颜色
                        settingsSection(title: "通用", icon: "paintpalette") {
                            themeColorPicker
                        }

                        // 播放设置
                        settingsSection(title: "播放设置", icon: "play.rectangle") {
                            orientationPicker
                            divider
                            defaultVolumeRow
                        }

                        settingsSection(title: "字幕与离线模型", icon: "captions.bubble") {
                            subtitleModelSettingsRow
                            divider
                            NavigationLink {
                                TranslationAPIManagementView()
                            } label: {
                                HStack {
                                    Image(systemName: "character.bubble")
                                        .foregroundColor(settings.themeColor.color)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text("翻译 API 管理").foregroundColor(.white)
                                        Text("系统翻译、智谱、火山及自定义服务")
                                            .font(.system(size: 12))
                                            .foregroundColor(.white.opacity(0.4))
                                    }
                                    Spacer()
                                    Image(systemName: "chevron.right")
                                        .foregroundColor(.white.opacity(0.3))
                                }
                                .padding(16)
                            }
                        }

                        // 私密文件夹
                        settingsSection(title: "私密文件夹", icon: "lock.shield") {
                            vaultShowToggle
                            divider
                            vaultBiometricsToggle
                        }

                        // 存储与缓存
                        settingsSection(title: "存储与缓存", icon: "internaldrive") {
                            cacheRow
                        }

                        // 还原设置
                        settingsSection(title: "重置", icon: "arrow.counterclockwise") {
                            resetRow
                        }

                        // 版本信息
                        versionInfo

                        Spacer(minLength: 40)
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 8)
                }
            }
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Text("设置")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundColor(.white)
                }
                #if os(iOS)
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("完成") { dismiss() }
                        .foregroundColor(settings.themeColor.color)
                        .fontWeight(.semibold)
                }
                #else
                ToolbarItem(placement: .automatic) {
                    Button("完成") { dismiss() }
                        .foregroundColor(settings.themeColor.color)
                        .fontWeight(.semibold)
                }
                #endif
            }
            #if os(iOS)
            .toolbarBackground(Color(red: 0.04, green: 0.04, blue: 0.05), for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            #endif
        }
        .onAppear { settings.refreshCacheSize() }
        .confirmationDialog("确认清除缓存？", isPresented: $showClearCacheConfirm, titleVisibility: .visible) {
            Button("清除缓存", role: .destructive) {
                isClearingCache = true
                Task {
                    await settings.clearCache()
                    isClearingCache = false
                    showClearCacheDone = true
                    try? await Task.sleep(nanoseconds: 1_800_000_000)
                    showClearCacheDone = false
                }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("这将清除所有临时缓存文件，不影响已导入视频。")
        }
        .confirmationDialog("还原所有设置？", isPresented: $showResetConfirm, titleVisibility: .visible) {
            Button("还原默认设置", role: .destructive) {
                withAnimation { settings.resetAllSettings() }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("将把所有设置恢复为出厂默认值，不影响已导入视频和保险箱密码。")
        }
    }

    // MARK: - Section 容器
    private func settingsSection<Content: View>(
        title: String,
        icon: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            // 组标题
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(settings.themeColor.color.opacity(0.85))
                Text(title.uppercased())
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.white.opacity(0.45))
            }
            .padding(.horizontal, 4)
            .padding(.bottom, 8)

            VStack(spacing: 0) {
                content()
            }
            .background(
                RoundedRectangle(cornerRadius: 14)
                    .fill(Color(red: 0.1, green: 0.11, blue: 0.13))
            )
        }
    }

    private var divider: some View {
        Rectangle()
            .fill(Color.white.opacity(0.07))
            .frame(height: 0.5)
            .padding(.horizontal, 16)
    }

    // MARK: - 主题颜色选择器
    private var themeColorPicker: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "circle.fill")
                    .foregroundColor(settings.themeColor.color)
                    .font(.system(size: 14))
                Text("主题颜色")
                    .font(.system(size: 16))
                    .foregroundColor(.white)
                Spacer()
                Text(settings.themeColor.displayName)
                    .font(.system(size: 13))
                    .foregroundColor(.white.opacity(0.45))
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)

            // 颜色球选择行
            HStack(spacing: 14) {
                ForEach(AppThemeColor.allCases, id: \.rawValue) { theme in
                    Button(action: {
                        withAnimation(.spring(response: 0.3)) {
                            settings.themeColor = theme
                        }
                    }) {
                        ZStack {
                            Circle()
                                .fill(theme.color)
                                .frame(width: 30, height: 30)
                            if settings.themeColor == theme {
                                Circle()
                                    .stroke(Color.white, lineWidth: 2.5)
                                    .frame(width: 36, height: 36)
                                Image(systemName: "checkmark")
                                    .font(.system(size: 11, weight: .bold))
                                    .foregroundColor(.white)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 14)
        }
    }

    // MARK: - 播放方向
    private var orientationPicker: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Image(systemName: settings.playbackOrientation.iconName)
                    .foregroundColor(settings.themeColor.color)
                    .font(.system(size: 14))
                    .frame(width: 22)
                Text("播放方向")
                    .font(.system(size: 16))
                    .foregroundColor(.white)
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)

            ForEach(PlaybackOrientation.allCases, id: \.rawValue) { orientation in
                Button(action: {
                    withAnimation { settings.playbackOrientation = orientation }
                }) {
                    HStack {
                        Text(orientation.displayName)
                            .font(.system(size: 15))
                            .foregroundColor(.white.opacity(0.85))
                        Spacer()
                        if settings.playbackOrientation == orientation {
                            Image(systemName: "checkmark")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundColor(settings.themeColor.color)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 11)
                    .background(
                        settings.playbackOrientation == orientation
                            ? settings.themeColor.color.opacity(0.08)
                            : Color.clear
                    )
                }
                .buttonStyle(.plain)

                if orientation != PlaybackOrientation.allCases.last {
                    divider
                }
            }
        }
    }

    // MARK: - 默认音量
    private var defaultVolumeRow: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "speaker.wave.2")
                    .foregroundColor(settings.themeColor.color)
                    .font(.system(size: 14))
                    .frame(width: 22)
                Text("默认音量")
                    .font(.system(size: 16))
                    .foregroundColor(.white)
                Spacer()
                Toggle("", isOn: $settings.useDefaultVolume)
                    .tint(settings.themeColor.color)
                    .labelsHidden()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)

            if settings.useDefaultVolume {
                VStack(spacing: 8) {
                    HStack {
                        Image(systemName: "speaker")
                            .font(.system(size: 12))
                            .foregroundColor(.white.opacity(0.4))
                        Slider(value: $settings.defaultVolume, in: 0...1, step: 0.05)
                            .tint(settings.themeColor.color)
                        Image(systemName: "speaker.wave.3")
                            .font(.system(size: 12))
                            .foregroundColor(.white.opacity(0.4))
                    }
                    .padding(.horizontal, 16)

                    Text("打开视频时音量：\(Int(settings.defaultVolume * 100))%")
                        .font(.system(size: 12))
                        .foregroundColor(.white.opacity(0.45))
                        .padding(.bottom, 12)
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: settings.useDefaultVolume)
    }

    private var subtitleModelSettingsRow: some View {
        NavigationLink {
            OfflineSubtitleSettingsView()
        } label: {
            HStack {
                Image(systemName: "waveform.and.mic")
                    .foregroundColor(settings.themeColor.color)
                    .font(.system(size: 14))
                    .frame(width: 22)
                VStack(alignment: .leading, spacing: 2) {
                    Text("离线字幕与模型")
                        .font(.system(size: 16))
                        .foregroundColor(.white)
                    Text("提前下载 WhisperKit、选择默认模型和完成提醒")
                        .font(.system(size: 12))
                        .foregroundColor(.white.opacity(0.4))
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 12))
                    .foregroundColor(.white.opacity(0.3))
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
        }
        .buttonStyle(.plain)
    }

    // MARK: - 私密保险箱 Tab 开关
    private var vaultShowToggle: some View {
        HStack {
            Image(systemName: "eye")
                .foregroundColor(settings.themeColor.color)
                .font(.system(size: 14))
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text("在列表显示")
                    .font(.system(size: 16))
                    .foregroundColor(.white)
                Text("在主页 Tab 栏中显示「私密文件夹」入口")
                    .font(.system(size: 12))
                    .foregroundColor(.white.opacity(0.4))
            }
            Spacer()
            Toggle("", isOn: $settings.showVaultInTabBar)
                .tint(settings.themeColor.color)
                .labelsHidden()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }

    // MARK: - 面容 ID 验证开关
    private var vaultBiometricsToggle: some View {
        HStack {
            Image(systemName: "faceid")
                .foregroundColor(settings.themeColor.color)
                .font(.system(size: 14))
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text("面容 ID 验证")
                    .font(.system(size: 16))
                    .foregroundColor(.white)
                Text("进入私密文件夹时需要 Face ID / Touch ID 验证")
                    .font(.system(size: 12))
                    .foregroundColor(.white.opacity(0.4))
            }
            Spacer()
            Toggle("", isOn: $settings.vaultRequiresBiometrics)
                .tint(settings.themeColor.color)
                .labelsHidden()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }

    // MARK: - 缓存行
    private var cacheRow: some View {
        Button(action: { showClearCacheConfirm = true }) {
            HStack {
                Image(systemName: "trash")
                    .foregroundColor(.red.opacity(0.85))
                    .font(.system(size: 14))
                    .frame(width: 22)
                VStack(alignment: .leading, spacing: 2) {
                    Text("清除缓存")
                        .font(.system(size: 16))
                        .foregroundColor(.white)
                    if isClearingCache {
                        Text("正在清除...")
                            .font(.system(size: 12))
                            .foregroundColor(.orange.opacity(0.8))
                    } else if showClearCacheDone {
                        Text("清除完成 ✓")
                            .font(.system(size: 12))
                            .foregroundColor(.green.opacity(0.8))
                    } else {
                        Text("当前缓存：\(settings.formattedCacheSize)")
                            .font(.system(size: 12))
                            .foregroundColor(.white.opacity(0.4))
                    }
                }
                Spacer()
                if isClearingCache {
                    ProgressView()
                        .tint(.white)
                        .scaleEffect(0.8)
                } else {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12))
                        .foregroundColor(.white.opacity(0.3))
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
        }
        .buttonStyle(.plain)
    }

    // MARK: - 还原所有设置
    private var resetRow: some View {
        Button(action: { showResetConfirm = true }) {
            HStack {
                Image(systemName: "arrow.counterclockwise.circle")
                    .foregroundColor(.orange.opacity(0.85))
                    .font(.system(size: 14))
                    .frame(width: 22)
                Text("还原所有设置")
                    .font(.system(size: 16))
                    .foregroundColor(.white)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 12))
                    .foregroundColor(.white.opacity(0.3))
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
        }
        .buttonStyle(.plain)
    }

    // MARK: - 版本信息
    private var versionInfo: some View {
        VStack(spacing: 4) {
            Text("LovortPlayer")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.white.opacity(0.3))
            Text("v1.0 · Lovort 沉浸黑灰 · AV1 软解引擎")
                .font(.system(size: 11))
                .foregroundColor(.white.opacity(0.2))
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 4)
    }
}

public struct TranslationAPIManagementView: View {
    @State private var provider = AISubtitleCoordinator.shared.translationProvider

    public init() {}

    public var body: some View {
        Form {
            Section {
                Picker("翻译服务", selection: $provider) {
                    ForEach(SubtitleTranslationProviderType.allCases) { item in
                        Text(item.displayName).tag(item)
                    }
                }
                .onChange(of: provider) { _, value in
                    AISubtitleCoordinator.shared.translationProvider = value
                }
            } footer: {
                Text("默认使用系统翻译。第三方服务未填写凭证时使用系统翻译；请求失败时保留原文字幕，可稍后重试。")
            }
            if provider == .apple {
                Section {
                    Text("首次使用需要下载语言包，请保持应用在前台并确认系统下载提示。下载完成后可在设备上离线翻译。")
                }
            } else {
                TranslationAPICredentialEditor(provider: provider).id(provider)
            }
        }
        .navigationTitle("翻译 API 管理")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }
}

private struct TranslationAPICredentialEditor: View {
    @ObservedObject private var modelManager = AIModelManager.shared
    let provider: SubtitleTranslationProviderType
    @State private var apiKey: String
    @State private var url: String
    @State private var model: String
    @State private var region: String
    @State private var authenticationMode: VolcengineAuthenticationMode
    @State private var accessKeyID: String
    @State private var secretAccessKey: String
    @State private var status = ""

    init(provider: SubtitleTranslationProviderType) {
        self.provider = provider
        let configuration = TranslationAPISettings(provider: provider)
        _url = State(initialValue: configuration.url)
        _model = State(initialValue: configuration.model)
        _authenticationMode = State(initialValue: configuration.authenticationMode)
        let accessCredentials = VolcengineAccessCredentials.saved()
        _accessKeyID = State(initialValue: accessCredentials.accessKeyID)
        _secretAccessKey = State(initialValue: accessCredentials.secretAccessKey)
        _apiKey = State(initialValue: provider == .openAI
            ? AISubtitleCoordinator.shared.getSavedOpenAIKey()
            : TranslationCredentialStore.shared.value(for: provider))
        _region = State(initialValue: UserDefaults.standard.string(forKey: "LovortAzureTranslatorRegion") ?? "")
    }

    var body: some View {
        Section {
            if provider == .volcengine {
                Picker("鉴权方式", selection: $authenticationMode) {
                    ForEach(VolcengineAuthenticationMode.allCases) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
            }
            if provider == .customChat {
                TextField("API URL（基础地址或完整 chat/completions 地址）", text: $url)
                    .autocorrectionDisabled()
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    .keyboardType(.URL)
                    #endif
                modelField
            } else if provider == .volcengine, authenticationMode == .accessKey {
                modelField
            } else if provider.usesChatCompletions {
                Text("已内置官方服务地址")
                    .font(.footnote).foregroundStyle(.secondary)
                DisclosureGroup("模型设置（已提供默认模型）") { modelField }
            }
            if provider == .volcengine, authenticationMode == .accessKey {
                SecureField("Access Key ID", text: $accessKeyID).autocorrectionDisabled()
                SecureField("Secret Access Key", text: $secretAccessKey).autocorrectionDisabled()
            } else {
                SecureField("API Key", text: $apiKey).autocorrectionDisabled()
            }
            if provider == .azure {
                TextField("Azure 区域（如 eastasia）", text: $region)
                    .autocorrectionDisabled()
            }
            if provider == .openAI {
                Text("测试模型：\(modelManager.selectedModelID)").font(.footnote).foregroundStyle(.secondary)
            }
            Button("保存配置") { save() }
            TranslationConnectionTestView(configuration: testConfiguration)
            if !status.isEmpty { Text(status).font(.footnote) }
        } footer: {
            Text(credentialHelp)
        }
    }

    private var testConfiguration: TranslationConnectionConfiguration {
        var settings = TranslationAPISettings(provider: provider)
        settings.url = url
        settings.model = model
        settings.authenticationMode = authenticationMode
        return TranslationConnectionConfiguration(
            settings: settings, apiKey: apiKey, azureRegion: region,
            accessCredentials: VolcengineAccessCredentials(accessKeyID: accessKeyID, secretAccessKey: secretAccessKey),
            openAIModel: modelManager.selectedModelID)
    }

    private var modelField: some View {
        TextField(provider == .volcengine && authenticationMode == .accessKey
            ? "接入点 ID（ep- 开头）" : "模型 ID", text: $model)
            .autocorrectionDisabled()
            #if os(iOS)
            .textInputAutocapitalization(.never)
            #endif
    }

    private var credentialHelp: String {
        if provider == .zhipu {
            return "智谱使用单个 API Key，无需 AK / SK。已提供默认字幕翻译模型，可在模型设置中修改。"
        }
        if provider == .volcengine {
            return authenticationMode == .accessKey
                ? "填写 AK、SK 和方舟接入点 ID。系统自动签名并获取仅用于该接入点的临时 API Key。请确认 IAM 用户有调用权限。清空 AK 和 SK 保存后使用系统翻译。"
                : "填写方舟 API Key 即可使用默认模型，也可修改为已开通的模型 ID。无需填写服务地址。清空 Key 保存后使用系统翻译。"
        }
        return provider.usesChatCompletions
            ? "使用 OpenAI 兼容的 Chat Completions 接口。Key 保存在设备钥匙串；字幕文本将发送至所填服务地址。"
            : "Key 保存在设备钥匙串；字幕文本将发送至所选服务。OpenAI 使用 Platform API Key。清空 Key 保存后使用系统翻译。"
    }

    private func save() {
        var configuration = TranslationAPISettings(provider: provider)
        configuration.url = url
        configuration.model = model
        configuration.authenticationMode = authenticationMode
        do {
            let accessCredentials = VolcengineAccessCredentials(accessKeyID: accessKeyID, secretAccessKey: secretAccessKey)
            let usesAccessKey = provider == .volcengine && authenticationMode == .accessKey
            let hasCredential = usesAccessKey ? !accessCredentials.isEmpty
                : !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            if usesAccessKey, hasCredential {
                try VolcengineAccessKeyTranslationProvider.validate(credentials: accessCredentials, endpointID: model)
            }
            if provider.usesChatCompletions, hasCredential {
                _ = try configuration.endpoint()
                guard !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    status = "请填写模型 ID 或接入点 ID"
                    return
                }
            }
            configuration.save()
            if usesAccessKey {
                accessCredentials.save()
            } else if provider == .openAI {
                AISubtitleCoordinator.shared.saveOpenAIKey(apiKey.trimmingCharacters(in: .whitespacesAndNewlines))
            } else {
                TranslationCredentialStore.shared.setValue(apiKey, for: provider)
            }
            if provider == .azure {
                UserDefaults.standard.set(region.trimmingCharacters(in: .whitespacesAndNewlines), forKey: "LovortAzureTranslatorRegion")
            }
            status = !hasCredential
                ? "已保存，将使用系统翻译" : "已保存，下一次字幕任务将使用此配置"
        } catch {
            status = error.localizedDescription
        }
    }
}
