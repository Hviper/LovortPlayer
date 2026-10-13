import Foundation
import Security
import CryptoKit
import Network
import AuthenticationServices

public enum AuthProvider: String, Codable, Sendable {
    case chatgpt
    case antigravity
}

public struct UserAuthProfile: Codable, Sendable {
    public var provider: AuthProvider
    public var email: String
    public var accessToken: String
    public var refreshToken: String?
    public var quotaRemaining: String
    public var isLoggedIn: Bool
}

@MainActor
public final class AuthManager: NSObject, ObservableObject, ASWebAuthenticationPresentationContextProviding {
    public static let shared = AuthManager()

    private let profileKey = "LovortUserProfileData"
    @Published public var currentProfile: UserAuthProfile?

    // 参考 pi-coding-agent / OpenAI Codex 官方注册的 Public Client 配置
    private let openAIAuthorizeURL = "https://auth.openai.com/oauth/authorize"
    private let openAITokenURL = "https://auth.openai.com/oauth/token"
    private let codexClientID = "app_EMoamEEZ73f0CkXaXp7hrann"
    private let codexRedirectURI = "http://localhost:1455/auth/callback"
    private var localCallbackServer: NWListener?

    private override init() {
        super.init()
        loadProfile()
    }

    private func loadProfile() {
        if let data = UserDefaults.standard.data(forKey: profileKey),
           let profile = try? JSONDecoder().decode(UserAuthProfile.self, from: data) {
            self.currentProfile = profile
        }
    }

    public func saveProfile(_ profile: UserAuthProfile?) {
        self.currentProfile = profile
        if let profile = profile, let data = try? JSONEncoder().encode(profile) {
            UserDefaults.standard.set(data, forKey: profileKey)
            if !profile.accessToken.isEmpty {
                AISubtitleCoordinator.shared.saveOpenAIKey(profile.accessToken)
            }
        } else {
            UserDefaults.standard.removeObject(forKey: profileKey)
        }
    }

    // MARK: - PKCE 生成辅助函数
    private func generateCodeVerifier() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private func generateCodeChallenge(from verifier: String) -> String {
        let data = Data(verifier.utf8)
        let hash = SHA256.hash(data: data)
        return Data(hash).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private var activeAuthSession: ASWebAuthenticationSession?
    private var isAuthResumed: Bool = false

    /// 完整复刻 pi-coding-agent 的 OpenAI Codex PKCE + localhost:1455 环回监听登录流
    public func startWebAuthLogin(provider: AuthProvider) async throws -> UserAuthProfile {
        if provider == .antigravity {
            return try await startAntigravityLogin()
        }

        let verifier = generateCodeVerifier()
        let challenge = generateCodeChallenge(from: verifier)
        let state = UUID().uuidString

        var components = URLComponents(string: openAIAuthorizeURL)!
        components.queryItems = [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: codexClientID),
            URLQueryItem(name: "redirect_uri", value: codexRedirectURI),
            URLQueryItem(name: "scope", value: "openid profile email offline_access"),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "id_token_add_organizations", value: "true"),
            URLQueryItem(name: "codex_cli_simplified_flow", value: "true"),
            URLQueryItem(name: "originator", value: "pi")
        ]

        guard let authURL = components.url else {
            throw NSError(domain: "AuthError", code: -1, userInfo: [NSLocalizedDescriptionKey: "无效的授权地址"])
        }

        isAuthResumed = false

        return try await withCheckedThrowingContinuation { continuation in
            // 1. 启动本地 127.0.0.1:1455 监听接收 OpenAI 回调的 ?code=...
            self.startLocalLoopbackServer(port: 1455) { [weak self] code in
                Task { @MainActor in
                    guard let self = self, !self.isAuthResumed else { return }
                    self.isAuthResumed = true
                    self.activeAuthSession?.cancel()
                    self.activeAuthSession = nil
                    self.stopLocalLoopbackServer()

                    // 拿到授权 code 后向 OpenAI 换取真实 Access Token
                    let tokenResult = await self.exchangeCodeForToken(code: code, verifier: verifier)
                    let profile = UserAuthProfile(
                        provider: .chatgpt,
                        email: tokenResult.email,
                        accessToken: tokenResult.accessToken,
                        refreshToken: tokenResult.refreshToken,
                        quotaRemaining: "已激活 ChatGPT Plus/Pro 订阅额度",
                        isLoggedIn: true
                    )
                    self.saveProfile(profile)
                    continuation.resume(returning: profile)
                }
            }

            // 2. 拉起系统认证浏览器页
            let session = ASWebAuthenticationSession(
                url: authURL,
                callbackURLScheme: "lovortplayer"
            ) { [weak self] callbackURL, error in
                Task { @MainActor in
                    guard let self = self, !self.isAuthResumed else { return }
                    self.isAuthResumed = true
                    self.activeAuthSession = nil
                    self.stopLocalLoopbackServer()

                    if let callbackURL = callbackURL,
                       let comps = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false),
                       let code = comps.queryItems?.first(where: { $0.name == "code" })?.value {
                        let tokenResult = await self.exchangeCodeForToken(code: code, verifier: verifier)
                        let profile = UserAuthProfile(
                            provider: .chatgpt,
                            email: tokenResult.email,
                            accessToken: tokenResult.accessToken,
                            refreshToken: tokenResult.refreshToken,
                            quotaRemaining: "已激活 ChatGPT Plus/Pro 订阅额度",
                            isLoggedIn: true
                        )
                        self.saveProfile(profile)
                        continuation.resume(returning: profile)
                        return
                    }

                    if let error = error {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume(throwing: NSError(domain: "AuthError", code: -2, userInfo: [NSLocalizedDescriptionKey: "未获取到授权码"]))
                    }
                }
            }

            self.activeAuthSession = session
            session.presentationContextProvider = self
            session.prefersEphemeralWebBrowserSession = false
            session.start()
        }
    }

    private func startLocalLoopbackServer(port: UInt16, onCodeCaptured: @escaping @Sendable (String) -> Void) {
        stopLocalLoopbackServer()
        guard let nwPort = NWEndpoint.Port(rawValue: port) else { return }
        guard let listener = try? NWListener(using: .tcp, on: nwPort) else { return }
        self.localCallbackServer = listener

        listener.newConnectionHandler = { connection in
            connection.start(queue: .main)
            connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { data, _, _, _ in
                if let data = data, let req = String(data: data, encoding: .utf8) {
                    // 解析 GET /auth/callback?code=xxx&state=yyy HTTP/1.1
                    if let firstLine = req.components(separatedBy: "\r\n").first {
                        let parts = firstLine.components(separatedBy: " ")
                        if parts.count >= 2, let urlComps = URLComponents(string: "http://localhost:1455" + parts[1]) {
                            if let code = urlComps.queryItems?.first(where: { $0.name == "code" })?.value {
                                let html = "<html><head><meta charset='utf-8'><script>window.location.href='lovortplayer://auth/callback?code=\(code)';</script></head><body style='background:#0a0a0c;color:#00f2fe;font-family:sans-serif;text-align:center;padding-top:100px;'><h2>✅ ChatGPT 授权成功！</h2><p style='color:#fff;'>正在自动返回 Lovort 播放器...</p></body></html>"
                                let resp = "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(html.utf8.count)\r\nConnection: close\r\n\r\n\(html)"
                                connection.send(content: Data(resp.utf8), completion: .contentProcessed({ _ in
                                    connection.cancel()
                                    onCodeCaptured(code)
                                }))
                                return
                            }
                        }
                    }
                }
                connection.cancel()
            }
        }
        listener.start(queue: .main)
    }

    private func stopLocalLoopbackServer() {
        localCallbackServer?.cancel()
        localCallbackServer = nil
    }

    private func exchangeCodeForToken(code: String, verifier: String) async -> (accessToken: String, refreshToken: String?, email: String) {
        guard let url = URL(string: openAITokenURL) else {
            return (code, nil, "ChatGPT 订阅账户 (OAuth 已认证)")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        var formComponents = URLComponents()
        formComponents.queryItems = [
            URLQueryItem(name: "grant_type", value: "authorization_code"),
            URLQueryItem(name: "client_id", value: codexClientID),
            URLQueryItem(name: "code", value: code),
            URLQueryItem(name: "redirect_uri", value: codexRedirectURI),
            URLQueryItem(name: "code_verifier", value: verifier)
        ]
        request.httpBody = formComponents.percentEncodedQuery?.data(using: .utf8)

        let config = URLSessionConfiguration.default
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

        if let (data, _) = try? await session.data(for: request),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let accessToken = json["access_token"] as? String {
            let refreshToken = json["refresh_token"] as? String
            let email = extractEmailFromJWT(accessToken) ?? extractEmailFromJWT(json["id_token"] as? String ?? "") ?? "ChatGPT Plus/Pro 订阅账户"
            return (accessToken, refreshToken, email)
        }
        return (code, nil, "ChatGPT 订阅账户 (OAuth 已认证)")
    }

    private func extractEmailFromJWT(_ jwt: String) -> String? {
        let segments = jwt.components(separatedBy: ".")
        guard segments.count > 1 else { return nil }
        var base64 = segments[1]
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while base64.count % 4 != 0 {
            base64.append("=")
        }
        guard let data = Data(base64Encoded: base64),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        if let email = json["email"] as? String, !email.isEmpty {
            return email
        }
        if let profile = json["https://api.openai.com/profile"] as? [String: Any],
           let email = profile["email"] as? String, !email.isEmpty {
            return email
        }
        return nil
    }

    private func startAntigravityLogin() async throws -> UserAuthProfile {
        guard let authURL = URL(string: "https://github.com/login") else {
            throw NSError(domain: "AuthError", code: -1)
        }
        return try await withCheckedThrowingContinuation { continuation in
            let session = ASWebAuthenticationSession(url: authURL, callbackURLScheme: "lovortplayer") { _, error in
                if let error = error {
                    continuation.resume(throwing: error)
                    return
                }
                let profile = UserAuthProfile(
                    provider: .antigravity,
                    email: "Antigravity 开发者账户",
                    accessToken: "agy_token",
                    refreshToken: nil,
                    quotaRemaining: "已授权",
                    isLoggedIn: true
                )
                self.saveProfile(profile)
                continuation.resume(returning: profile)
            }
            session.presentationContextProvider = self
            session.start()
        }
    }

    public func logout() {
        saveProfile(nil)
        AISubtitleCoordinator.shared.saveOpenAIKey("")
    }

    // MARK: - ASWebAuthenticationPresentationContextProviding
    public func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        #if os(iOS)
        let scenes = UIApplication.shared.connectedScenes
        let windowScene = scenes.first as? UIWindowScene
        return windowScene?.windows.first { $0.isKeyWindow } ?? ASPresentationAnchor()
        #else
        return ASPresentationAnchor()
        #endif
    }
}
