import AuthenticationServices
import CryptoKit
import Foundation
import Network
import Security
#if os(iOS)
import UIKit
#endif

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
    public var clientID: String?
    public var idToken: String?
    public var scopes: [String]?
    public var expiresAt: Date?

    public var canUseChatGPTPlan: Bool {
        scopes?.contains("chatgpt.tokens.use.direct") == true
    }
}

@MainActor
public final class AuthManager: NSObject, ObservableObject, ASWebAuthenticationPresentationContextProviding {
    public static let shared = AuthManager()

    private struct OAuthCallback: Sendable {
        let code: String?
        let state: String?
        let clientID: String?
        let error: String?
    }

    private struct TokenResult: Sendable {
        let accessToken: String
        let refreshToken: String?
        let idToken: String
        let scopes: [String]
        let expiresAt: Date
        let email: String
    }

    private let profileKey = "LovortUserProfileData"
    private let keychainService = "com.hviper.lovortplayer.chatgpt"
    private let hostIDKey = "LovortChatGPTHostID"
    private let authorizeURL = "https://auth.openai.com/api/accounts/authorize"
    private let tokenURL = "https://auth.openai.com/api/accounts/oauth/token"
    private let resource = "https://api.openai.com/v1"
    private let redirectURI = "http://127.0.0.1:1455/auth/callback"
    private let dynamicClientID = "dynamic_agent_client"

    @Published public var currentProfile: UserAuthProfile?
    private var localCallbackServer: NWListener?
    private var activeAuthSession: ASWebAuthenticationSession?
    private var isAuthResumed = false

    private override init() {
        super.init()
        loadProfile()
    }

    private func loadProfile() {
        if let data = readProfileFromKeychain(),
           let profile = try? JSONDecoder().decode(UserAuthProfile.self, from: data) {
            currentProfile = profile
            return
        }
        if let legacyData = UserDefaults.standard.data(forKey: profileKey),
           let profile = try? JSONDecoder().decode(UserAuthProfile.self, from: legacyData) {
            currentProfile = profile
            clearLegacyOAuthToken(matching: profile.accessToken)
            saveProfile(profile)
            UserDefaults.standard.removeObject(forKey: profileKey)
        }
    }

    public func saveProfile(_ profile: UserAuthProfile?) {
        currentProfile = profile
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: profileKey
        ]
        SecItemDelete(query as CFDictionary)
        guard let profile, let data = try? JSONEncoder().encode(profile) else { return }
        var item = query
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(item as CFDictionary, nil)
    }

    private func readProfileFromKeychain() -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: profileKey,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else { return nil }
        return result as? Data
    }

    private func hostID() -> String {
        if let saved = UserDefaults.standard.string(forKey: hostIDKey), !saved.isEmpty { return saved }
        let value = "urn:uuid:\(UUID().uuidString.lowercased())"
        UserDefaults.standard.set(value, forKey: hostIDKey)
        return value
    }

    private func generateCodeVerifier() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes).base64URLEncodedString()
    }

    private func generateCodeChallenge(from verifier: String) -> String {
        Data(SHA256.hash(data: Data(verifier.utf8))).base64URLEncodedString()
    }

    public func startWebAuthLogin(provider: AuthProvider) async throws -> UserAuthProfile {
        if provider == .antigravity { return try await startAntigravityLogin() }

        let verifier = generateCodeVerifier()
        let challenge = generateCodeChallenge(from: verifier)
        let state = UUID().uuidString
        let nonce = UUID().uuidString
        let savedClientID = currentProfile?.provider == .chatgpt ? currentProfile?.clientID : nil
        let pendingClientID = savedClientID ?? dynamicClientID

        var components = URLComponents(string: authorizeURL)!
        var queryItems = [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: pendingClientID),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "scope", value: "openid profile email offline_access resource.invoke chatgpt.tokens.use.direct"),
            URLQueryItem(name: "resource", value: resource),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "nonce", value: nonce),
            URLQueryItem(name: "ext_agent_host_id", value: hostID())
        ]
        if pendingClientID == dynamicClientID {
            queryItems.append(URLQueryItem(name: "agent_name_hint", value: "LovortPlayer"))
        } else {
            if let idToken = currentProfile?.idToken {
                queryItems.append(URLQueryItem(name: "id_token_hint", value: idToken))
            }
            if let email = currentProfile?.email, !email.isEmpty {
                queryItems.append(URLQueryItem(name: "login_hint", value: email))
            }
        }
        components.queryItems = queryItems
        guard let authURL = components.url else { throw authError("无法生成 ChatGPT 授权地址") }

        isAuthResumed = false
        return try await withCheckedThrowingContinuation { continuation in
            startLocalLoopbackServer(port: 1455) { [weak self] callback in
                Task { @MainActor in
                    guard let self, !self.isAuthResumed else { return }
                    self.isAuthResumed = true
                    self.activeAuthSession?.cancel()
                    self.activeAuthSession = nil
                    self.stopLocalLoopbackServer()
                    do {
                        let profile = try await self.finishLogin(
                            callback: callback,
                            expectedState: state,
                            pendingClientID: pendingClientID,
                            verifier: verifier,
                            nonce: nonce
                        )
                        continuation.resume(returning: profile)
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }

            let session = ASWebAuthenticationSession(url: authURL, callbackURLScheme: "lovortplayer") { [weak self] callbackURL, error in
                Task { @MainActor in
                    guard let self, !self.isAuthResumed else { return }
                    if let callbackURL {
                        self.isAuthResumed = true
                        self.stopLocalLoopbackServer()
                        self.activeAuthSession = nil
                        do {
                            let profile = try await self.finishLogin(
                                callback: Self.parseCallback(url: callbackURL),
                                expectedState: state,
                                pendingClientID: pendingClientID,
                                verifier: verifier,
                                nonce: nonce
                            )
                            continuation.resume(returning: profile)
                        } catch {
                            continuation.resume(throwing: error)
                        }
                    } else if let error {
                        self.isAuthResumed = true
                        self.stopLocalLoopbackServer()
                        self.activeAuthSession = nil
                        continuation.resume(throwing: error)
                    }
                }
            }
            activeAuthSession = session
            session.presentationContextProvider = self
            session.prefersEphemeralWebBrowserSession = false
            guard session.start() else {
                isAuthResumed = true
                stopLocalLoopbackServer()
                continuation.resume(throwing: authError("无法打开系统登录窗口"))
                return
            }
        }
    }

    private func finishLogin(
        callback: OAuthCallback,
        expectedState: String,
        pendingClientID: String,
        verifier: String,
        nonce: String
    ) async throws -> UserAuthProfile {
        guard callback.state == expectedState else { throw authError("登录状态校验失败，请重新发起授权") }
        if let error = callback.error { throw authError("ChatGPT 未授权：\(error)") }
        guard let code = callback.code, !code.isEmpty else { throw authError("登录回调缺少授权码") }

        let issuedClientID: String
        if pendingClientID == dynamicClientID {
            guard let callbackClientID = callback.clientID, !callbackClientID.isEmpty else {
                throw authError("ChatGPT 动态注册未返回 client_id")
            }
            issuedClientID = callbackClientID
        } else {
            if let callbackClientID = callback.clientID, callbackClientID != pendingClientID {
                throw authError("登录回调的 client_id 与已保存账户不一致")
            }
            issuedClientID = pendingClientID
        }

        let token = try await exchangeCodeForToken(
            code: code,
            verifier: verifier,
            clientID: issuedClientID,
            nonce: nonce
        )
        guard token.scopes.contains("chatgpt.tokens.use.direct") else {
            throw authError("已登录，但未授予“使用 ChatGPT 计划”权限")
        }
        let profile = UserAuthProfile(
            provider: .chatgpt,
            email: token.email,
            accessToken: token.accessToken,
            refreshToken: token.refreshToken,
            quotaRemaining: "ChatGPT 计划使用权限已启用",
            isLoggedIn: true,
            clientID: issuedClientID,
            idToken: token.idToken,
            scopes: token.scopes,
            expiresAt: token.expiresAt
        )
        saveProfile(profile)
        return profile
    }

    private func startLocalLoopbackServer(port: UInt16, onCallback: @escaping @Sendable (OAuthCallback) -> Void) {
        stopLocalLoopbackServer()
        guard let nwPort = NWEndpoint.Port(rawValue: port),
              let listener = try? NWListener(using: .tcp, on: nwPort) else { return }
        localCallbackServer = listener
        listener.newConnectionHandler = { connection in
            connection.start(queue: .main)
            connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { data, _, _, _ in
                guard let data,
                      let request = String(data: data, encoding: .utf8),
                      let requestTarget = request.components(separatedBy: "\r\n").first?.components(separatedBy: " ").dropFirst().first,
                      let callbackURL = URL(string: "http://127.0.0.1:\(port)\(requestTarget)") else {
                    connection.cancel()
                    return
                }
                let callback = Self.parseCallback(url: callbackURL)
                let successful = callback.code != nil && callback.error == nil
                let title = successful ? "ChatGPT 授权完成" : "ChatGPT 授权未完成"
                let body = "<html><head><meta charset='utf-8'></head><body style='font-family:-apple-system;text-align:center;padding-top:80px;background:#0a0a0c;color:white'><h2>\(title)</h2><p>现在可以返回 LovortPlayer。</p></body></html>"
                let response = "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
                connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in
                    connection.cancel()
                    onCallback(callback)
                })
            }
        }
        listener.start(queue: .main)
    }

    private nonisolated static func parseCallback(url: URL) -> OAuthCallback {
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func value(_ name: String) -> String? { items.first(where: { $0.name == name })?.value }
        return OAuthCallback(code: value("code"), state: value("state"), clientID: value("client_id"), error: value("error"))
    }

    private func stopLocalLoopbackServer() {
        localCallbackServer?.cancel()
        localCallbackServer = nil
    }

    private func exchangeCodeForToken(
        code: String,
        verifier: String,
        clientID: String,
        nonce: String
    ) async throws -> TokenResult {
        guard let url = URL(string: tokenURL) else { throw authError("无效的令牌地址") }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var form = URLComponents()
        form.queryItems = [
            URLQueryItem(name: "grant_type", value: "authorization_code"),
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "code", value: code),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "code_verifier", value: verifier),
            URLQueryItem(name: "resource", value: resource)
        ]
        request.httpBody = form.percentEncodedQuery?.data(using: .utf8)

        let (data, response) = try await proxyAwareSession().data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode),
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let accessToken = json["access_token"] as? String,
              let idToken = json["id_token"] as? String else {
            let message = String(decoding: data.prefix(800), as: UTF8.self)
            throw authError("令牌交换失败：\(message)")
        }

        let claims = try await validateIDToken(idToken, clientID: clientID, nonce: nonce)
        let scopeValue = (json["scope"] as? String) ?? (extractJWTClaims(accessToken)?["scope"] as? String) ?? ""
        let scopes = scopeValue.split(separator: " ").map(String.init)
        let expiresIn = (json["expires_in"] as? NSNumber)?.doubleValue ?? 3_600
        let email = (claims["email"] as? String)
            ?? ((claims["https://api.openai.com/profile"] as? [String: Any])?["email"] as? String)
            ?? "ChatGPT 账户"
        return TokenResult(
            accessToken: accessToken,
            refreshToken: json["refresh_token"] as? String,
            idToken: idToken,
            scopes: scopes,
            expiresAt: Date().addingTimeInterval(expiresIn),
            email: email
        )
    }

    private func validateIDToken(_ token: String, clientID: String, nonce: String) async throws -> [String: Any] {
        let segments = token.components(separatedBy: ".")
        guard segments.count == 3,
              let headerData = Data(base64URLEncoded: segments[0]),
              let header = try JSONSerialization.jsonObject(with: headerData) as? [String: Any],
              header["alg"] as? String == "RS256",
              let keyID = header["kid"] as? String,
              let signature = Data(base64URLEncoded: segments[2]) else {
            throw authError("ID Token 头部或签名格式无效")
        }
        guard let jwksURL = URL(string: "https://auth.openai.com/.well-known/jwks.json") else {
            throw authError("OpenAI JWKS 地址无效")
        }
        let (jwksData, response) = try await proxyAwareSession().data(from: jwksURL)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode),
              let jwks = try JSONSerialization.jsonObject(with: jwksData) as? [String: Any],
              let keys = jwks["keys"] as? [[String: Any]],
              let jwk = keys.first(where: { $0["kid"] as? String == keyID }),
              jwk["kty"] as? String == "RSA",
              let modulusValue = jwk["n"] as? String,
              let exponentValue = jwk["e"] as? String,
              let modulus = Data(base64URLEncoded: modulusValue),
              let exponent = Data(base64URLEncoded: exponentValue),
              let publicKey = rsaPublicKey(modulus: modulus, exponent: exponent) else {
            throw authError("无法获取 OpenAI ID Token 公钥")
        }
        let signedData = Data("\(segments[0]).\(segments[1])".utf8)
        var verificationError: Unmanaged<CFError>?
        guard SecKeyVerifySignature(
            publicKey,
            .rsaSignatureMessagePKCS1v15SHA256,
            signedData as CFData,
            signature as CFData,
            &verificationError
        ) else {
            throw authError("OpenAI ID Token 签名校验失败")
        }

        guard let claims = extractJWTClaims(token) else { throw authError("无法解析 OpenAI ID Token") }
        guard claims["iss"] as? String == "https://auth.openai.com" else { throw authError("ID Token 签发方无效") }
        let audienceMatches: Bool
        if let audience = claims["aud"] as? String {
            audienceMatches = audience == clientID
        } else if let audiences = claims["aud"] as? [String] {
            audienceMatches = audiences.contains(clientID)
        } else {
            audienceMatches = false
        }
        guard audienceMatches else { throw authError("ID Token 受众无效") }
        guard claims["nonce"] as? String == nonce else { throw authError("ID Token nonce 校验失败") }
        guard let expiry = (claims["exp"] as? NSNumber)?.doubleValue, expiry > Date().timeIntervalSince1970 else {
            throw authError("ID Token 已过期")
        }
        return claims
    }

    private func rsaPublicKey(modulus: Data, exponent: Data) -> SecKey? {
        let encodedKey = asn1Sequence(asn1Integer(modulus) + asn1Integer(exponent))
        let attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecAttrKeyClass as String: kSecAttrKeyClassPublic,
            kSecAttrKeySizeInBits as String: modulus.count * 8
        ]
        return SecKeyCreateWithData(encodedKey as CFData, attributes as CFDictionary, nil)
    }

    private func asn1Integer(_ value: Data) -> Data {
        var bytes = [UInt8](value)
        while bytes.count > 1, bytes.first == 0, bytes[1] & 0x80 == 0 { bytes.removeFirst() }
        if let first = bytes.first, first & 0x80 != 0 { bytes.insert(0, at: 0) }
        return Data([0x02]) + asn1Length(bytes.count) + Data(bytes)
    }

    private func asn1Sequence(_ value: Data) -> Data {
        Data([0x30]) + asn1Length(value.count) + value
    }

    private func asn1Length(_ length: Int) -> Data {
        if length < 128 { return Data([UInt8(length)]) }
        var value = length
        var bytes: [UInt8] = []
        while value > 0 {
            bytes.insert(UInt8(value & 0xff), at: 0)
            value >>= 8
        }
        return Data([0x80 | UInt8(bytes.count)]) + Data(bytes)
    }

    private func extractJWTClaims(_ jwt: String) -> [String: Any]? {
        let segments = jwt.components(separatedBy: ".")
        guard segments.count == 3, let data = Data(base64URLEncoded: segments[1]) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    public func accessTokenForRequests() async throws -> String? {
        guard var profile = currentProfile, profile.provider == .chatgpt, profile.isLoggedIn else { return nil }
        guard profile.canUseChatGPTPlan else {
            throw authError("当前登录记录没有 ChatGPT 计划使用权限，请退出后重新登录授权")
        }
        if let expiresAt = profile.expiresAt, expiresAt > Date().addingTimeInterval(90) {
            return profile.accessToken
        }
        guard let refreshToken = profile.refreshToken,
              let clientID = profile.clientID,
              let url = URL(string: tokenURL) else {
            throw authError("ChatGPT 登录已过期，请重新登录")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var form = URLComponents()
        form.queryItems = [
            URLQueryItem(name: "grant_type", value: "refresh_token"),
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "refresh_token", value: refreshToken),
            URLQueryItem(name: "resource", value: resource)
        ]
        request.httpBody = form.percentEncodedQuery?.data(using: .utf8)
        let (data, response) = try await proxyAwareSession().data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode),
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let accessToken = json["access_token"] as? String else {
            throw authError("ChatGPT 凭据刷新失败，请重新登录")
        }
        let scopeValue = (json["scope"] as? String) ?? profile.scopes?.joined(separator: " ") ?? ""
        let scopes = scopeValue.split(separator: " ").map(String.init)
        guard scopes.contains("chatgpt.tokens.use.direct") else {
            throw authError("刷新后的凭据不再包含 ChatGPT 计划使用权限")
        }
        profile.accessToken = accessToken
        profile.refreshToken = (json["refresh_token"] as? String) ?? refreshToken
        profile.idToken = (json["id_token"] as? String) ?? profile.idToken
        profile.scopes = scopes
        let expiresIn = (json["expires_in"] as? NSNumber)?.doubleValue ?? 3_600
        profile.expiresAt = Date().addingTimeInterval(expiresIn)
        saveProfile(profile)
        return accessToken
    }

    private func proxyAwareSession() -> URLSession {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 60
        let host = UserDefaults.standard.string(forKey: "LovortCustomProxyHost") ?? ""
        let port = UserDefaults.standard.integer(forKey: "LovortCustomProxyPort")
        if !host.isEmpty, port > 0 {
            configuration.connectionProxyDictionary = [
                "HTTPEnable": 1, "HTTPProxy": host, "HTTPPort": port,
                "HTTPSEnable": 1, "HTTPSProxy": host, "HTTPSPort": port
            ]
        }
        return URLSession(configuration: configuration)
    }

    private func startAntigravityLogin() async throws -> UserAuthProfile {
        throw authError("Antigravity 登录尚未配置")
    }

    public func logout() {
        if let accessToken = currentProfile?.accessToken {
            clearLegacyOAuthToken(matching: accessToken)
        }
        saveProfile(nil)
    }

    private func clearLegacyOAuthToken(matching accessToken: String) {
        let key = "LovortOpenAIAPIKey"
        if UserDefaults.standard.string(forKey: key) == accessToken {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }

    private func authError(_ message: String) -> NSError {
        NSError(domain: "AuthError", code: -1, userInfo: [NSLocalizedDescriptionKey: message])
    }

    public func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        #if os(iOS)
        let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene
        return scene?.windows.first(where: \.isKeyWindow) ?? ASPresentationAnchor()
        #else
        return ASPresentationAnchor()
        #endif
    }
}

private extension Data {
    init?<S: StringProtocol>(base64URLEncoded value: S) {
        var base64 = String(value).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while base64.count % 4 != 0 { base64.append("=") }
        self.init(base64Encoded: base64)
    }

    func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
