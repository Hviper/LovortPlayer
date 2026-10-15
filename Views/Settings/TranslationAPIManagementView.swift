#if canImport(LovortPlayerCore)
import LovortPlayerCore
#endif
import SwiftUI

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
                Text("默认使用系统翻译。OpenAI 可使用 ChatGPT 订阅登录或 Platform API Key；其他第三方服务未填写凭证时使用系统翻译。")
            }
            if provider == .apple {
                Section {
                    Text("首次使用需要下载语言包，请保持应用在前台并确认系统下载提示。下载完成后可在设备上离线翻译。")
                }
            } else {
                if provider == .openAI {
                    ChatGPTSubscriptionManagementSection()
                }
                TranslationAPICredentialEditor(provider: provider).id(provider)
            }
        }
        .navigationTitle("翻译 API 管理")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }
}

private struct ChatGPTSubscriptionManagementSection: View {
    @StateObject private var authManager = AuthManager.shared
    @State private var isLoggingIn = false
    @State private var status = ""

    var body: some View {
        Section {
            if let profile = authManager.currentProfile, profile.isLoggedIn {
                LabeledContent("账户", value: profile.email)
                Label(
                    profile.canUseChatGPTPlan ? "已连接，可用于字幕翻译和语境精修" : "当前授权未包含 ChatGPT 模型使用权限",
                    systemImage: profile.canUseChatGPTPlan ? "checkmark.shield.fill" : "exclamationmark.triangle.fill"
                )
                .foregroundStyle(profile.canUseChatGPTPlan ? .green : .orange)
                Button("退出 ChatGPT 登录", role: .destructive) {
                    authManager.logout()
                    status = ""
                }
            } else {
                Button {
                    Task {
                        isLoggingIn = true
                        defer { isLoggingIn = false }
                        do {
                            let profile = try await authManager.startWebAuthLogin(provider: .chatgpt)
                            status = profile.canUseChatGPTPlan
                                ? "ChatGPT 订阅已连接"
                                : "登录成功，但账户未授予模型使用权限"
                        } catch {
                            status = "登录未完成：\(error.localizedDescription)"
                        }
                    }
                } label: {
                    Label(isLoggingIn ? "正在打开登录…" : "通过 Safari 登录 ChatGPT", systemImage: "safari.fill")
                }
                .disabled(isLoggingIn)
            }
            if !status.isEmpty { Text(status).font(.footnote) }
        } header: {
            Text("ChatGPT 订阅")
        } footer: {
            Text("订阅登录仅用于 GPT 文本翻译与精修。离线 WhisperKit 和 Mac 转写无需登录；OpenAI Whisper 云端音频转写仍需 Platform API Key。")
        }
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
        let accessCredentials = VolcengineAccessCredentials.saved(for: provider)
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
            if provider == .volcengineMachineTranslation {
                Text("官方机器翻译地址已内置，无需模型或接入点").font(.footnote).foregroundStyle(.secondary)
            }
            if usesAccessKeyCredentials {
                SecureField("Access Key ID", text: $accessKeyID).autocorrectionDisabled()
                SecureField("Secret Access Key", text: $secretAccessKey).autocorrectionDisabled()
            } else {
                SecureField(provider == .openAI ? "OpenAI Platform API Key（可选）" : "API Key", text: $apiKey)
                    .autocorrectionDisabled()
            }
            if provider == .azure {
                TextField("Azure 区域（如 eastasia）", text: $region)
                    .autocorrectionDisabled()
            }
            if provider == .openAI {
                Text("测试模型：\(modelManager.selectedModelID)").font(.footnote).foregroundStyle(.secondary)
            }
            Button("保存配置") { save() }
            if provider != .openAI || apiKey.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("sk-") {
                TranslationConnectionTestView(configuration: testConfiguration)
            }
            if !status.isEmpty { Text(status).font(.footnote) }
        } footer: {
            Text(credentialHelp)
        }
    }

    private var usesAccessKeyCredentials: Bool {
        provider == .volcengineMachineTranslation || (provider == .volcengine && authenticationMode == .accessKey)
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
        if provider == .volcengineMachineTranslation {
            return "火山引擎机器翻译（TranslateText）。官方地址已内置，只需填写 AK/SK，无需模型、接入点或 API Key。请先开通机器翻译服务并授予调用权限；清空 AK 和 SK 保存后使用系统翻译。"
        }
        if provider == .zhipu {
            return "智谱使用单个 API Key，无需 AK / SK。已提供默认字幕翻译模型，可在模型设置中修改。"
        }
        if provider == .volcengine {
            return authenticationMode == .accessKey
                ? "填写 AK、SK 和方舟接入点 ID。系统自动签名并获取仅用于该接入点的临时 API Key。请确认 IAM 用户有调用权限。清空 AK 和 SK 保存后使用系统翻译。"
                : "填写方舟 API Key 即可使用默认模型，也可修改为已开通的模型 ID。无需填写服务地址。清空 Key 保存后使用系统翻译。"
        }
        if provider == .openAI {
            return "Platform API Key 是可选备用方式，填写后优先使用，并可用于 OpenAI Whisper 云端音频转写。清空 Key 后，GPT 文本翻译与精修使用上方 ChatGPT 订阅登录。"
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
            let usesAccessKey = usesAccessKeyCredentials
            let hasCredential = usesAccessKey ? !accessCredentials.isEmpty
                : !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            if provider == .volcengine, usesAccessKey, hasCredential {
                try VolcengineAccessKeyTranslationProvider.validate(credentials: accessCredentials, endpointID: model)
            }
            if provider.usesChatCompletions, hasCredential {
                _ = try configuration.endpoint()
                guard !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    status = "请填写模型 ID 或接入点 ID"
                    return
                }
            }
            if provider == .volcengineMachineTranslation, hasCredential, !accessCredentials.isComplete {
                status = "请填写完整的 Access Key ID 和 Secret Access Key"
                return
            }
            configuration.save()
            if usesAccessKey {
                accessCredentials.save(for: provider)
            } else if provider == .openAI {
                AISubtitleCoordinator.shared.saveOpenAIKey(apiKey.trimmingCharacters(in: .whitespacesAndNewlines))
            } else {
                TranslationCredentialStore.shared.setValue(apiKey, for: provider)
            }
            if provider == .azure {
                UserDefaults.standard.set(region.trimmingCharacters(in: .whitespacesAndNewlines), forKey: "LovortAzureTranslatorRegion")
            }
            status = provider == .openAI && !hasCredential
                ? "已清除 Platform API Key，GPT 文本功能将使用 ChatGPT 订阅登录"
                : (!hasCredential ? "已保存，将使用系统翻译" : "已保存，下一次字幕任务将使用此配置")
        } catch {
            status = error.localizedDescription
        }
    }
}
