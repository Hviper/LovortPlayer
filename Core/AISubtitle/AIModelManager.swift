import Foundation
import SwiftUI
import Combine

public struct AIModelInfo: Identifiable, Hashable, Sendable {
    public let id: String
    public let displayName: String
    public let description: String
    public let badge: String?

    public init(id: String, displayName: String, description: String, badge: String? = nil) {
        self.id = id
        self.displayName = displayName
        self.description = description
        self.badge = badge
    }
}

@MainActor
public final class AIModelManager: ObservableObject {
    public static let shared = AIModelManager()

    private let storageKey = "LovortSelectedAIModelID"

    /// 内置的经典与主流模型选项（覆盖 GPT-4o 旗舰、Mini 极速、Codex 专线与推理模型）
    public static let defaultModels: [AIModelInfo] = [
        AIModelInfo(
            id: "gpt-4o-mini",
            displayName: "GPT-4o Mini",
            description: "响应极速，性价比最高，日常双语字幕首选",
            badge: "极速推荐"
        ),
        AIModelInfo(
            id: "gpt-4o",
            displayName: "GPT-4o (全能旗舰)",
            description: "影视俚语与多角色口吻理解最自然，翻译质量顶级",
            badge: "旗舰高精"
        ),
        AIModelInfo(
            id: "gpt-5.1-codex-mini",
            displayName: "Codex Mini (专线)",
            description: "ChatGPT 订阅专线通道，长篇字幕格式对齐最稳",
            badge: "订阅专享"
        ),
        AIModelInfo(
            id: "o3-mini",
            displayName: "o3-mini (深度推理)",
            description: "具备思维链深度理解，擅长科技/学术/复杂专业片",
            badge: "深度推理"
        ),
        AIModelInfo(
            id: "chatgpt-4o-latest",
            displayName: "ChatGPT-4o Latest",
            description: "OpenAI 官方持续迭代的最前沿 GPT-4o 模型",
            badge: "前沿版"
        )
    ]

    @Published public var availableModels: [AIModelInfo] = defaultModels
    @Published public var selectedModelID: String = "gpt-4o-mini" {
        didSet {
            UserDefaults.standard.set(selectedModelID, forKey: storageKey)
        }
    }
    @Published public var isFetchingModels: Bool = false
    @Published public var fetchMessage: String? = nil

    private init() {
        let saved = UserDefaults.standard.string(forKey: storageKey) ?? "gpt-4o-mini"
        self.selectedModelID = saved
    }

    /// 获取当前选中模型的展示信息
    public var currentModelInfo: AIModelInfo {
        if let found = availableModels.first(where: { $0.id == selectedModelID }) {
            return found
        }
        return AIModelInfo(
            id: selectedModelID,
            displayName: selectedModelID,
            description: "自定义选择模型",
            badge: "自定义"
        )
    }

    /// 切换模型
    public func selectModel(_ id: String) {
        self.selectedModelID = id
    }

    /// 异步向 OpenAI 获取当前订阅/API Key 真实支持的模型列表
    public func fetchAvailableModels(token: String) async {
        guard !token.isEmpty else { return }

        isFetchingModels = true
        fetchMessage = "正在获取可用模型列表..."

        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 15

        let proxyHost = UserDefaults.standard.string(forKey: "LovortCustomProxyHost") ?? ""
        let proxyPort = UserDefaults.standard.integer(forKey: "LovortCustomProxyPort")
        if !proxyHost.isEmpty && proxyPort > 0 {
            config.connectionProxyDictionary = [
                "HTTPEnable": 1,
                "HTTPProxy": proxyHost,
                "HTTPPort": proxyPort,
                "HTTPSEnable": 1,
                "HTTPSProxy": proxyHost,
                "HTTPSPort": proxyPort
            ]
        }
        let session = URLSession(configuration: config)

        // 尝试拉取 /v1/models 接口
        guard let url = URL(string: "https://api.openai.com/v1/models") else {
            isFetchingModels = false
            return
        }

        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        do {
            let (data, response) = try await session.data(for: request)
            if let httpResp = response as? HTTPURLResponse, (200...299).contains(httpResp.statusCode),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let list = json["data"] as? [[String: Any]] {

                var fetchedIDs: [String] = []
                for item in list {
                    if let id = item["id"] as? String {
                        // 过滤出适合文本与字幕翻译的 GPT/o1/o3/codex 系列模型
                        let lower = id.lowercased()
                        if lower.contains("gpt-4") || lower.contains("gpt-5") || lower.contains("codex") || lower.contains("o3-mini") || lower.contains("o1") {
                            if !lower.contains("vision") && !lower.contains("audio") && !lower.contains("realtime") && !lower.contains("embedding") {
                                fetchedIDs.append(id)
                            }
                        }
                    }
                }

                if !fetchedIDs.isEmpty {
                    // 合并去重
                    var merged: [AIModelInfo] = Self.defaultModels
                    for fId in fetchedIDs {
                        if !merged.contains(where: { $0.id == fId }) {
                            merged.append(
                                AIModelInfo(
                                    id: fId,
                                    displayName: fId,
                                    description: "订阅账户动态发现可用模型",
                                    badge: "订阅可用"
                                )
                            )
                        }
                    }
                    self.availableModels = merged
                    self.fetchMessage = "已同步最新可用模型 (\(merged.count) 个)"
                } else {
                    self.fetchMessage = "已加载推荐模型列表"
                }
            } else {
                self.fetchMessage = "已加载推荐模型列表"
            }
        } catch {
            self.fetchMessage = "已加载推荐模型列表"
        }

        isFetchingModels = false
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            self.fetchMessage = nil
        }
    }
}
