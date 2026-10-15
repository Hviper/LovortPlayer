import Foundation
import XCTest
@testable import LovortPlayerCore

final class TranslationAPITests: XCTestCase {
    func testEndpointAcceptsBaseAndFullURLWithoutDuplicatingPath() throws {
        var settings = TranslationAPISettings(provider: .customChat)
        settings.url = "https://example.com/v1/"
        XCTAssertEqual(try settings.endpoint().absoluteString, "https://example.com/v1/chat/completions")
        settings.url = "https://example.com/v1/chat/completions/"
        XCTAssertEqual(try settings.endpoint().absoluteString, "https://example.com/v1/chat/completions")
        for invalid in ["", "not a url", "http://example.com", "https://key@example.com/v1", "https://example.com?key=secret"] {
            settings.url = invalid
            XCTAssertThrowsError(try settings.endpoint())
        }
    }

    func testUnconfiguredProviderUsesSystemTranslation() {
        for provider in SubtitleTranslationProviderType.allCases {
            let expected: SubtitleTranslationProviderType = provider == .openAI ? .openAI : .apple
            XCTAssertEqual(TranslationAPISettings.effectiveProvider(provider, hasCredential: false), expected)
            XCTAssertEqual(TranslationAPISettings.effectiveProvider(provider, hasCredential: true), provider)
        }
    }

    func testChatGPTSubscriptionTranslationUsesOnlyCodexTextEndpoint() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ChatGPTSubscriptionURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let lines = [
            SubtitleLine(startTime: 1, endTime: 2, originalText: "Hello"),
            SubtitleLine(startTime: 3, endTime: 4, originalText: "Bye")
        ]

        let result = try await ChatGPTSubscriptionTranslationProvider(
            tokenProvider: { _ in ChatGPTSubscriptionURLProtocol.token },
            model: "gpt-6.1-sol",
            session: session
        ).translate(lines: lines, sourceLanguage: .english,
                    targetLanguage: "中文 (简体)", onProgress: nil)

        XCTAssertEqual(result.map(\.id), lines.map(\.id))
        XCTAssertEqual(result.map(\.originalText), ["Hello", "Bye"])
        XCTAssertEqual(result.map(\.translatedText), ["你好", "再见"])
    }

    func testChatGPTSubscriptionRefreshesOnceAfterUnauthorizedResponse() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ChatGPTRefreshURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let recorder = TokenRequestRecorder()

        let result = try await ChatGPTSubscriptionTranslationProvider(
            tokenProvider: { forceRefresh in
                await recorder.append(forceRefresh)
                return forceRefresh ? ChatGPTRefreshURLProtocol.refreshedToken : "expired-token"
            },
            model: "gpt-6.1-sol",
            session: session
        ).translate(
            lines: [SubtitleLine(startTime: 0, endTime: 1, originalText: "Hello")],
            sourceLanguage: .english,
            targetLanguage: "中文 (简体)",
            onProgress: nil
        )

        let refreshRequests = await recorder.values()
        XCTAssertEqual(refreshRequests, [false, true])
        XCTAssertEqual(result.first?.translatedText, "你好")
    }

    func testOpenAIExecutionIdentitySeparatesChannelModelAndCredential() {
        let platform = OpenAITranslationExecutionConfiguration(
            channel: .platformAPI, model: "model-a",
            credentialFingerprint: OpenAITranslationExecutionConfiguration.fingerprint("sk-one")
        )
        let subscription = OpenAITranslationExecutionConfiguration(
            channel: .chatGPTSubscription, model: "model-a",
            credentialFingerprint: OpenAITranslationExecutionConfiguration.fingerprint("account-one")
        )
        let anotherModel = OpenAITranslationExecutionConfiguration(
            channel: .platformAPI, model: "model-b",
            credentialFingerprint: OpenAITranslationExecutionConfiguration.fingerprint("sk-one")
        )
        XCTAssertNotEqual(platform.cacheIdentity, subscription.cacheIdentity)
        XCTAssertNotEqual(platform.cacheIdentity, anotherModel.cacheIdentity)
        XCTAssertFalse(platform.cacheIdentity.contains("sk-one"))

        let settings = TranslationAPISettings(provider: .openAI)
        XCTAssertEqual(settings.effectiveCacheIdentity(openAIConfiguration: platform, enhanceWithGPT: false),
                       platform.cacheIdentity)
    }

    func testCacheIdentityChangesWithEndpointOrModel() {
        var settings = TranslationAPISettings(provider: .customChat)
        settings.url = "https://example.com/v1"
        settings.model = "model-a"
        let original = settings.cacheIdentity
        settings.model = "model-b"
        XCTAssertNotEqual(settings.cacheIdentity, original)
        settings.model = "model-a"
        settings.url = "https://another.example.com/v1"
        XCTAssertNotEqual(settings.cacheIdentity, original)
        XCTAssertNil(TranslationAPISettings(provider: .apple).cacheIdentity)
    }

    func testChatTranslationPreservesOriginalsTimestampsAndIDs() async throws {
        let lines = [SubtitleLine(startTime: 1, endTime: 2, originalText: "Hello"),
                     SubtitleLine(startTime: 3, endTime: 4, originalText: "Bye")]
        let result = try await provider(host: "success.invalid").translate(
            lines: lines, sourceLanguage: .english, targetLanguage: "中文 (简体)", onProgress: nil)
        XCTAssertEqual(result.map(\.id), lines.map(\.id))
        XCTAssertEqual(result.map(\.originalText), ["Hello", "Bye"])
        XCTAssertEqual(result.map(\.translatedText), ["你好", "再见"])
        XCTAssertEqual(result.map(\.startTime), [1, 3])
        XCTAssertEqual(result.map(\.endTime), [2, 4])
    }

    func testHTTPFailureAndEmptyTranslationDoNotReturnFalseSuccess() async {
        let lines = [SubtitleLine(startTime: 1, endTime: 2, originalText: "Hello"),
                     SubtitleLine(startTime: 3, endTime: 4, originalText: "Bye")]
        for host in ["failure.invalid", "empty.invalid", "missing.invalid"] {
            do {
                _ = try await provider(host: host).translate(
                    lines: lines, sourceLanguage: .english, targetLanguage: "中文 (简体)", onProgress: nil)
                XCTFail("Expected failure for \(host)")
            } catch {
                XCTAssertFalse(error.localizedDescription.contains("test-secret"))
            }
        }
        XCTAssertEqual(lines.map(\.originalText), ["Hello", "Bye"])
        XCTAssertTrue(lines.allSatisfy { $0.translatedText == nil })
    }

    @MainActor
    func testMissingAppleSessionFailsPromptlyAndReleasesPendingRequest() async {
        let bridge = AppleTranslationBridge(sessionStartTimeout: 0)
        let lines = [SubtitleLine(startTime: 0, endTime: 1, originalText: "Hello")]
        for _ in 0..<2 {
            do {
                _ = try await bridge.translate(lines: lines, sourceLanguage: .english,
                    targetLanguage: "中文 (简体)", onProgress: nil)
                XCTFail("A missing view session must fail instead of hanging")
            } catch {
                XCTAssertTrue(error.localizedDescription.contains("会话未启动"))
            }
        }
    }

    @MainActor
    func testAppleCancellationClearsPendingAndRepeatInvalidatesConfiguration() async throws {
        let bridge = AppleTranslationBridge.shared
        let lines = [SubtitleLine(startTime: 0, endTime: 1, originalText: "Hello")]
        let first = Task {
            try await bridge.translate(lines: lines, sourceLanguage: .english,
                                       targetLanguage: "中文 (简体)", onProgress: nil)
        }
        try await Task.sleep(for: .milliseconds(10))
        let previous = bridge.configuration
        XCTAssertNotNil(previous)
        first.cancel()
        do { _ = try await first.value; XCTFail("Expected cancellation") } catch is CancellationError {} catch { XCTFail("\(error)") }
        let second = Task {
            try await bridge.translate(lines: lines, sourceLanguage: .english,
                                       targetLanguage: "中文 (简体)", onProgress: nil)
        }
        try await Task.sleep(for: .milliseconds(10))
        XCTAssertNotEqual(bridge.configuration, previous)
        second.cancel()
        do { _ = try await second.value; XCTFail("Expected cancellation") } catch is CancellationError {} catch { XCTFail("\(error)") }
    }

    func testDocumentKeepsRequestConfigurationWhenLiveSettingsChange() {
        var settings = TranslationAPISettings(provider: .customChat)
        settings.url = "https://example.com/v1"
        settings.model = "original-model"
        let requestConfiguration = settings.cacheIdentity
        settings.model = "changed-model"
        let document = SubtitleDocument(sourceLanguage: "english", targetLanguage: "中文",
            engine: .localWhisperKit, model: nil, translationProvider: .customChat,
            translationConfiguration: requestConfiguration,
            lines: [SubtitleLine(startTime: 0, endTime: 1, originalText: "Hello", translatedText: "你好")])
        XCTAssertEqual(document.translationConfiguration, requestConfiguration)
        XCTAssertNotEqual(document.translationConfiguration, settings.cacheIdentity)
    }

    func testOfficialProviderAddressesCannotBeOverriddenAndHaveDefaultModels() throws {
        for provider in [SubtitleTranslationProviderType.zhipu, .volcengine] {
            var settings = TranslationAPISettings(provider: provider)
            let original = try settings.endpoint()
            settings.url = "https://untrusted.invalid/v1"
            XCTAssertEqual(try settings.endpoint(), original)
            XCTAssertFalse(settings.model.isEmpty)
        }
    }

    func testVolcengineSignatureMatchesOfficialPythonSDKVector() throws {
        let credentials = VolcengineAccessCredentials(accessKeyID: "test-ak", secretAccessKey: "test-sk")
        let request = try VolcengineAccessKeyTranslationProvider.temporaryKeyRequest(
            credentials: credentials, endpointID: "ep-test", date: Date(timeIntervalSince1970: 0))
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"),
            "HMAC-SHA256 Credential=test-ak/19700101/cn-beijing/ark/request, SignedHeaders=content-type;host;x-content-sha256;x-date, Signature=066acce18b9acb7087662990a249460b1d420c1496a4a5c85fe2faa36f69edc6")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Date"), "19700101T000000Z")
        XCTAssertFalse(String(decoding: request.httpBody!, as: UTF8.self).contains("test-sk"))
        XCTAssertThrowsError(try VolcengineAccessKeyTranslationProvider.temporaryKeyRequest(
            credentials: credentials, endpointID: "doubao-model"))
        XCTAssertThrowsError(try VolcengineAccessKeyTranslationProvider.temporaryKeyRequest(
            credentials: VolcengineAccessCredentials(accessKeyID: "test-ak", secretAccessKey: ""), endpointID: "ep-test"))
    }

    @MainActor
    func testVolcengineAccessKeysExchangeTokenBeforeTranslatingAndKeepErrorsPrivate() async throws {
        var settings = TranslationAPISettings(provider: .volcengine)
        settings.model = "ep-test"
        settings.authenticationMode = .accessKey
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [VolcengineTestURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let lines = [SubtitleLine(startTime: 1, endTime: 2, originalText: "Hello")]
        let result = try await VolcengineAccessKeyTranslationProvider(settings: settings,
            credentials: VolcengineAccessCredentials(accessKeyID: "test-ak", secretAccessKey: "test-sk"), session: session)
            .translate(lines: lines, sourceLanguage: .english, targetLanguage: "中文", onProgress: nil)
        XCTAssertEqual(result.first?.translatedText, "你好")
        XCTAssertEqual(result.first?.id, lines.first?.id)
        do {
            _ = try await VolcengineAccessKeyTranslationProvider(settings: settings,
                credentials: VolcengineAccessCredentials(accessKeyID: "deny-ak", secretAccessKey: "test-sk"), session: session)
                .translate(lines: lines, sourceLanguage: .english, targetLanguage: "中文", onProgress: nil)
            XCTFail("Expected rejected AK/SK to fail")
        } catch {
            XCTAssertFalse(error.localizedDescription.contains("test-sk"))
            XCTAssertFalse(error.localizedDescription.contains("private-server-payload"))
        }
    }

    private func provider(host: String) -> ChatCompletionTranslationProvider {
        var settings = TranslationAPISettings(provider: .customChat)
        settings.url = "https://\(host)/v1"
        settings.model = "test-model"
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [TranslationTestURLProtocol.self]
        return ChatCompletionTranslationProvider(settings: settings, apiKey: "test-secret",
                                                  session: URLSession(configuration: configuration))
    }
}

private final class TranslationTestURLProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard request.httpMethod == "POST",
              request.url?.path == "/v1/chat/completions",
              request.value(forHTTPHeaderField: "Authorization") == "Bearer test-secret" else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        let host = request.url?.host
        let status = host == "failure.invalid" ? 401 : 200
        let content: String
        switch host {
        case "empty.invalid": content = "[{\"index\":0,\"translation\":\" \"},{\"index\":1,\"translation\":\"再见\"}]"
        case "missing.invalid": content = "[{\"index\":0,\"translation\":\"你好\"}]"
        default: content = "[{\"index\":1,\"translation\":\"再见\"},{\"index\":0,\"translation\":\"你好\"}]"
        }
        let body: [String: Any] = status == 401 ? ["error": ["message": "test-secret"]]
            : ["choices": [["message": ["content": content]]]]
        let data = try! JSONSerialization.data(withJSONObject: body)
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

private final class ChatGPTSubscriptionURLProtocol: URLProtocol, @unchecked Sendable {
    static let token = "header.eyJodHRwczovL2FwaS5vcGVuYWkuY29tL2F1dGgiOnsiY2hhdGdwdF9hY2NvdW50X2lkIjoiYWNjdC10ZXN0In19.signature"

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard request.url?.absoluteString == "https://chatgpt.com/backend-api/codex/responses",
              request.httpMethod == "POST",
              request.value(forHTTPHeaderField: "Authorization") == "Bearer \(Self.token)",
              request.value(forHTTPHeaderField: "chatgpt-account-id") == "acct-test",
              request.value(forHTTPHeaderField: "OpenAI-Beta") == "responses=experimental",
              let body = request.httpBody,
              let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              object["model"] as? String == "gpt-6.1-sol",
              object["store"] as? Bool == false else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        let content = "[{\"index\":1,\"translation\":\"再见\"},{\"index\":0,\"translation\":\"你好\"}]"
        let payload: [String: Any] = ["output": [["content": [["type": "output_text", "text": content]]]]]
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: try! JSONSerialization.data(withJSONObject: payload))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

private actor TokenRequestRecorder {
    private var requests: [Bool] = []
    func append(_ forceRefresh: Bool) { requests.append(forceRefresh) }
    func values() -> [Bool] { requests }
}

private final class ChatGPTRefreshURLProtocol: URLProtocol, @unchecked Sendable {
    static let refreshedToken = "header.eyJodHRwczovL2FwaS5vcGVuYWkuY29tL2F1dGgiOnsiY2hhdGdwdF9hY2NvdW50X2lkIjoiYWNjdC10ZXN0In19.signature"

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let authorized = request.value(forHTTPHeaderField: "Authorization") == "Bearer \(Self.refreshedToken)"
        let status = authorized ? 200 : 401
        let body: [String: Any]
        if authorized {
            let content = "[{\"index\":0,\"translation\":\"你好\"}]"
            body = ["output": [["content": [["type": "output_text", "text": content]]]]]
        } else {
            body = ["error": ["message": "expired"]]
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: try! JSONSerialization.data(withJSONObject: body))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

private final class VolcengineTestURLProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let header = request.value(forHTTPHeaderField: "Authorization") ?? ""
        let url = request.url!
        let status: Int
        let body: [String: Any]
        if url.host == "ark.cn-beijing.volcengineapi.com",
           url.query == "Action=GetApiKey&Version=2024-01-01", header.hasPrefix("HMAC-SHA256 Credential=") {
            status = header.contains("deny-ak/") ? 403 : 200
            body = status == 403 ? ["error": "test-sk private-server-payload"] : ["Result": ["ApiKey": "temporary-test-token"]]
        } else if url.host == "ark.cn-beijing.volces.com", url.path == "/api/v3/chat/completions",
                  header == "Bearer temporary-test-token" {
            status = 200
            body = ["choices": [["message": ["content": "[{\"index\":0,\"translation\":\"你好\"}]"]]]]
        } else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: try! JSONSerialization.data(withJSONObject: body))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

final class TranslationConnectionTests: XCTestCase {
    @MainActor
    func testDraftConnectionUsesExactModelWithoutSaving() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ConnectionTestURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let draft = TranslationConnectionConfiguration(settings: TranslationAPISettings(provider: .openAI),
            apiKey: "sk-test-only", openAIModel: "test-selected-model")
        let previousModel = AIModelManager.shared.selectedModelID
        let value = try await TranslationConnectionTester.test(draft, session: session)
        XCTAssertEqual(value, "你好")
        XCTAssertEqual(AIModelManager.shared.selectedModelID, previousModel)
    }

    @MainActor
    func testInvalidSelectedGPTModelCannotPassByFallingBack() async {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ConnectionTestURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let draft = TranslationConnectionConfiguration(settings: TranslationAPISettings(provider: .openAI),
            apiKey: "sk-test-only", openAIModel: "unavailable-model")
        do {
            _ = try await TranslationConnectionTester.test(draft, session: session)
            XCTFail("The exact selected model must fail; fallback must not hide the failure")
        } catch {
            XCTAssertTrue(TranslationConnectionTester.errorMessage(error).contains("404"))
            XCTAssertFalse(TranslationConnectionTester.errorMessage(error).contains("sk-test-only"))
        }
    }

    @MainActor
    func testEmptyCredentialAndEmptyResponseCannotPass() async {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ConnectionTestURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        for (key, model) in [("", "test-selected-model"), ("sk-test-only", "empty-model")] {
            do {
                _ = try await TranslationConnectionTester.test(TranslationConnectionConfiguration(
                    settings: TranslationAPISettings(provider: .openAI), apiKey: key, openAIModel: model), session: session)
                XCTFail("Invalid credentials and empty output must fail")
            } catch {}
        }
        let secretError = NSError(domain: "SubtitleTranslationProvider", code: -1,
            userInfo: [NSLocalizedDescriptionKey: "HTTP 401 sk-test-only echoed-server-body"])
        let message = TranslationConnectionTester.errorMessage(secretError)
        XCTAssertTrue(message.contains("401"))
        XCTAssertFalse(message.contains("sk-test-only"))
        XCTAssertFalse(message.contains("echoed-server-body"))
    }

    @MainActor
    func testCustomDraftTestsInputWithoutPersisting() async throws {
        let network = URLSessionConfiguration.ephemeral
        network.protocolClasses = [ConnectionTestURLProtocol.self]
        let session = URLSession(configuration: network)
        defer { session.invalidateAndCancel() }
        let before = TranslationAPISettings(provider: .customChat)
        var draft = before
        draft.url = "https://draft-test.invalid/v1"
        draft.model = "test-selected-model"
        let value = try await TranslationConnectionTester.test(TranslationConnectionConfiguration(
            settings: draft, apiKey: "draft-secret"), session: session)
        XCTAssertEqual(value, "你好")
        XCTAssertEqual(TranslationAPISettings(provider: .customChat), before)
    }
}

private final class ConnectionTestURLProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        var body = request.httpBody
        if body == nil, let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var data = Data()
            var bytes = [UInt8](repeating: 0, count: 1024)
            while stream.hasBytesAvailable {
                let count = stream.read(&bytes, maxLength: bytes.count)
                guard count > 0 else { break }
                data.append(bytes, count: count)
            }
            body = data
        }
        let object = (try? JSONSerialization.jsonObject(with: body ?? Data())) as? [String: Any]
        let model = object?["model"] as? String ?? ""
        let status = model == "unavailable-model" ? 404 : 200
        let text = model == "empty-model" ? " " : model == "test-selected-model" ? "你好" : "备用模型"
        let content = "[{\"index\":0,\"translation\":\"\(text)\"}]"
        let payload: [String: Any]
        if status == 404 {
            payload = ["error": ["message": "sk-test-only echoed-server-body"]]
        } else if request.url?.path == "/v1/responses" {
            guard request.httpMethod == "POST", object?["store"] as? Bool == false,
                  (object?["input"] as? String)?.contains("Hello.") == true else {
                client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse)); return
            }
            payload = ["output_text": content]
        } else {
            guard request.url?.host == "draft-test.invalid", request.url?.path == "/v1/chat/completions",
                  model == "test-selected-model", request.value(forHTTPHeaderField: "Authorization") == "Bearer draft-secret" else {
                client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse)); return
            }
            payload = ["choices": [["message": ["content": content]]]]
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: try! JSONSerialization.data(withJSONObject: payload))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

final class VolcengineMachineTranslationTests: XCTestCase {
    func testMachineRequestUsesOfficialEndpointSignatureAndLanguageCodes() throws {
        let credentials = VolcengineAccessCredentials(accessKeyID: "test-ak", secretAccessKey: "test-sk")
        let lines = [SubtitleLine(startTime: 0, endTime: 1, originalText: "Hello.")]
        let request = try VolcengineMachineTranslationProvider.translationRequest(credentials: credentials,
            lines: lines, source: .english, target: "简体中文", date: Date(timeIntervalSince1970: 0))
        XCTAssertEqual(request.url?.absoluteString, "https://translate.volcengineapi.com/?Action=TranslateText&Version=2020-06-01")
        XCTAssertEqual(String(decoding: request.httpBody!, as: UTF8.self), "{\"SourceLanguage\":\"en\",\"TargetLanguage\":\"zh\",\"TextList\":[\"Hello.\"]}")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"),
            "HMAC-SHA256 Credential=test-ak/19700101/cn-north-1/translate/request, SignedHeaders=content-type;host;x-content-sha256;x-date, Signature=7f7ed8753250f51f6efa2122117c0f0f74ffa782b91dd34e6bda033b0320ba29")
        let automatic = try VolcengineMachineTranslationProvider.translationRequest(credentials: credentials,
            lines: lines, source: .automatic, target: "中文 (繁體)")
        let body = try JSONSerialization.jsonObject(with: automatic.httpBody!) as! [String: Any]
        XCTAssertNil(body["SourceLanguage"])
        XCTAssertEqual(body["TargetLanguage"] as? String, "zh-Hant")
        XCTAssertFalse(SubtitleTranslationProviderType.volcengineMachineTranslation.usesChatCompletions)
        XCTAssertTrue(TranslationAPISettings(provider: .volcengineMachineTranslation).usesAccessKeyCredentials)
    }

    func testMachineBatchesEnforceCountAndCharacterLimits() throws {
        let lines = (0..<33).map { SubtitleLine(startTime: Double($0), endTime: Double($0+1), originalText: "Hello") }
        XCTAssertEqual(try VolcengineMachineTranslationProvider.batches(lines).map(\.count), [16,16,1])
        let longLines = (0..<3).map { SubtitleLine(startTime: Double($0), endTime: Double($0+1), originalText: String(repeating: "文", count: 2_000)) }
        XCTAssertEqual(try VolcengineMachineTranslationProvider.batches(longLines).map(\.count), [2,1])
        XCTAssertThrowsError(try VolcengineMachineTranslationProvider.batches([
            SubtitleLine(startTime: 0, endTime: 1, originalText: String(repeating: "文", count: 5_001))]))
    }

    @MainActor
    func testMachineTranslationAndConnectionTestPreserveSubtitles() async throws {
        let session = session()
        defer { session.invalidateAndCancel() }
        let credentials = VolcengineAccessCredentials(accessKeyID: "test-ak", secretAccessKey: "test-sk")
        let lines = (0..<17).map { SubtitleLine(startTime: Double($0), endTime: Double($0+1), originalText: "Hello.") }
        let output = try await VolcengineMachineTranslationProvider(credentials: credentials, session: session)
            .translate(lines: lines, sourceLanguage: .automatic, targetLanguage: "中文 (简体)", onProgress: nil)
        XCTAssertEqual(output.map(\.id), lines.map(\.id))
        XCTAssertEqual(output.map(\.startTime), lines.map(\.startTime))
        XCTAssertEqual(output.map(\.endTime), lines.map(\.endTime))
        XCTAssertEqual(output.map(\.originalText), lines.map(\.originalText))
        XCTAssertTrue(output.allSatisfy { $0.translatedText == "你好" })
        let value = try await TranslationConnectionTester.test(TranslationConnectionConfiguration(
            settings: TranslationAPISettings(provider: .volcengineMachineTranslation), apiKey: "",
            accessCredentials: credentials), session: session)
        XCTAssertEqual(value, "你好")
    }

    @MainActor
    func testMachineErrorsEmptyResultsAndIncompleteCredentialsFailPrivately() async {
        let session = session()
        defer { session.invalidateAndCancel() }
        let credentials = VolcengineAccessCredentials(accessKeyID: "test-ak", secretAccessKey: "test-sk")
        for text in ["api-error", "http-error", "empty", "missing"] {
            do {
                _ = try await VolcengineMachineTranslationProvider(credentials: credentials, session: session).translate(
                    lines: [SubtitleLine(startTime: 0, endTime: 1, originalText: text)],
                    sourceLanguage: .english, targetLanguage: "简体中文", onProgress: nil)
                XCTFail("Invalid response must fail")
            } catch {
                XCTAssertFalse(error.localizedDescription.contains("test-sk"))
                XCTAssertFalse(TranslationConnectionTester.errorMessage(error).contains("echoed-body"))
            }
        }
        do {
            _ = try await TranslationConnectionTester.test(TranslationConnectionConfiguration(
                settings: TranslationAPISettings(provider: .volcengineMachineTranslation), apiKey: "ignored",
                accessCredentials: .init(accessKeyID: "", secretAccessKey: "test-sk")), session: session)
            XCTFail("Both AK and SK are required; no fallback")
        } catch {
            XCTAssertTrue(TranslationConnectionTester.errorMessage(error).contains("完整"))
        }
    }

    private func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MachineTranslationURLProtocol.self]
        return URLSession(configuration: configuration)
    }
}

private final class MachineTranslationURLProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        var data = request.httpBody ?? Data()
        if data.isEmpty, let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 1024)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                guard count > 0 else { break }
                data.append(buffer, count: count)
            }
        }
        guard request.url?.host == "translate.volcengineapi.com", request.url?.query == "Action=TranslateText&Version=2020-06-01",
              request.httpMethod == "POST", (request.value(forHTTPHeaderField: "Authorization") ?? "").contains("cn-north-1/translate/request"),
              let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let texts = body["TextList"] as? [String], !texts.isEmpty, texts.count <= 16,
              texts.reduce(0, { $0 + $1.utf16.count }) <= 5_000, body["model"] == nil, body["messages"] == nil else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse)); return
        }
        var root: [String: Any] = ["TranslationList": texts.map { _ in ["Translation": "你好"] }]
        switch texts.first {
        case "api-error": root = ["ResponseMetadata": ["Error": ["Code": "AccessDenied", "Message": "test-sk echoed-body"]]]
        case "empty": root = ["TranslationList": [["Translation": " "]]]
        case "missing": root = ["TranslationList": []]
        default: break
        }
        let status = texts.first == "http-error" ? 403 : 200
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: try! JSONSerialization.data(withJSONObject: root))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
