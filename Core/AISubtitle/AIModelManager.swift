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

    /// 内置的前沿主流模型选项（全面覆盖 GPT-6 Sol/Astra/Luna 旗舰与 GPT-5.6 系列）
    public static let defaultModels: [AIModelInfo] = [
        AIModelInfo(
            id: "gpt-6.1-sol",
            displayName: "GPT-6.1 Sol",
            description: "高智商深度推理与动漫俚语解析，双语字幕首选",
            badge: "主力推荐"
        ),
        AIModelInfo(
            id: "gpt-6-astra",
            displayName: "GPT-6 Astra",
            description: "GPT-6 顶配旗舰大模型，影视口吻与多角色理解顶级",
            badge: "全能旗舰"
        ),
        AIModelInfo(
            id: "gpt-6-sol",
            displayName: "GPT-6 Sol",
            description: "GPT-6 均衡主力模型，影视字幕极速高精翻译",
            badge: "均衡推荐"
        ),
        AIModelInfo(
            id: "gpt-6-luna",
            displayName: "GPT-6 Luna",
            description: "GPT-6 极速轻量模型，超低延迟处理长篇字幕",
            badge: "轻量极速"
        ),
        AIModelInfo(
            id: "gpt-5.6-sol",
            displayName: "GPT-5.6 Sol",
            description: "GPT-5.6 均衡主力模型，长文本稳定性极佳",
            badge: "高精稳定"
        ),
        AIModelInfo(
            id: "gpt-5.6-terra",
            displayName: "GPT-5.6 Terra",
            description: "GPT-5.6 专业批处理模型，适合长篇连续剧字幕",
            badge: "专业批量"
        ),
        AIModelInfo(
            id: "gpt-5.6-luna",
            displayName: "GPT-5.6 Luna",
            description: "GPT-5.6 极速轻量模型，基础台词极速对齐",
            badge: "轻量版"
        ),
        AIModelInfo(
            id: "gpt-4o-mini",
            displayName: "GPT-4o Mini",
            description: "经典轻量模型，日常快速翻译",
            badge: "经典"
        ),
        AIModelInfo(
            id: "gpt-4o",
            displayName: "GPT-4o",
            description: "经典全能旗舰模型",
            badge: "经典"
        ),
        AIModelInfo(
            id: "gpt-5.1-codex-mini",
            displayName: "Codex Mini (专线)",
            description: "ChatGPT 订阅专线通道，长篇字幕格式对齐稳定",
            badge: "专线"
        )
    ]

    @Published public var availableModels: [AIModelInfo] = defaultModels
    @Published public var selectedModelID: String = "gpt-6.1-sol" {
        didSet {
            UserDefaults.standard.set(selectedModelID, forKey: storageKey)
        }
    }
    @Published public var isFetchingModels: Bool = false
    @Published public var fetchMessage: String? = nil

    private init() {
        let saved = UserDefaults.standard.string(forKey: storageKey) ?? "gpt-6.1-sol"
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
            description: "当前选择模型",
            badge: "当前使用"
        )
    }

    /// 切换模型
    public func selectModel(_ id: String) {
        self.selectedModelID = id
    }

    /// 异步向 OpenAI / ChatGPT 获取当前订阅真实支持的模型列表
    public func fetchAvailableModels(token: String) async {
        guard !token.isEmpty else { return }

        isFetchingModels = true
        fetchMessage = "正在探测账户可用模型..."

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

        // 提取 chatgpt-account-id
        var accountID: String? = nil
        let segments = token.components(separatedBy: ".")
        if segments.count > 1 {
            var b64 = segments[1].replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
            while b64.count % 4 != 0 { b64.append("=") }
            if let d = Data(base64Encoded: b64),
               let json = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
               let authClaim = json["https://api.openai.com/auth"] as? [String: Any] {
                accountID = authClaim["chatgpt_account_id"] as? String
            }
        }

        var candidateURLs: [URL] = []
        if token.hasPrefix("sk-") {
            if let u = URL(string: "https://api.openai.com/v1/models") { candidateURLs.append(u) }
        } else {
            // ChatGPT OAuth / 订阅接口
            if let u1 = URL(string: "https://chatgpt.com/backend-api/models?history_and_training_disabled=false") { candidateURLs.append(u1) }
            if let u2 = URL(string: "https://chatgpt.com/backend-api/models") { candidateURLs.append(u2) }
            if let u3 = URL(string: "https://api.openai.com/v1/models") { candidateURLs.append(u3) }
        }

        var fetchedIDs: [String] = []

        for url in candidateURLs {
            var request = URLRequest(url: url)
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            if let accountID = accountID {
                request.setValue(accountID, forHTTPHeaderField: "chatgpt-account-id")
            }

            if let (data, response) = try? await session.data(for: request),
               let httpResp = response as? HTTPURLResponse, (200...299).contains(httpResp.statusCode),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {

                // 处理 {"data": [{"id": "..."}]}
                if let list = json["data"] as? [[String: Any]] {
                    for item in list {
                        if let id = item["id"] as? String {
                            fetchedIDs.append(id)
                        }
                    }
                }
                // 处理 {"models": [{"slug": "...", "title": "..."}]}
                if let models = json["models"] as? [[String: Any]] {
                    for item in models {
                        if let slug = item["slug"] as? String {
                            fetchedIDs.append(slug)
                        } else if let id = item["id"] as? String {
                            fetchedIDs.append(id)
                        }
                    }
                }
                // 处理 categories
                if let cats = json["categories"] as? [[String: Any]] {
                    for cat in cats {
                        if let defModel = cat["default_model"] as? String {
                            fetchedIDs.append(defModel)
                        }
                    }
                }

                if !fetchedIDs.isEmpty {
                    break
                }
            }
        }

        // 过滤与格式化模型列表
        var validIDs: [String] = []
        for id in fetchedIDs {
            let lower = id.lowercased()
            if lower.contains("gpt-6") || lower.contains("gpt-5") || lower.contains("sol") || lower.contains("astra") || lower.contains("terra") || lower.contains("luna") || lower.contains("gpt-4") || lower.contains("o3") || lower.contains("o1") || lower.contains("codex") {
                if !lower.contains("embedding") && !lower.contains("tts") && !lower.contains("moderation") {
                    if !validIDs.contains(id) {
                        validIDs.append(id)
                    }
                }
            }
        }

        if !validIDs.isEmpty {
            var merged = Self.defaultModels
            for vId in validIDs {
                if !merged.contains(where: { $0.id.lowercased() == vId.lowercased() }) {
                    merged.append(
                        AIModelInfo(
                            id: vId,
                            displayName: vId,
                            description: "账户云端发现可用模型",
                            badge: "订阅可用"
                        )
                    )
                }
            }
            self.availableModels = merged
            self.fetchMessage = "已同步云端可用模型 (\(merged.count) 个)"
        } else {
            self.fetchMessage = "已加载推荐模型列表 (GPT-6 / GPT-5.6 系列)"
        }

        isFetchingModels = false
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            self.fetchMessage = nil
        }
    }
}
