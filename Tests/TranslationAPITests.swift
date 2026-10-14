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
            XCTAssertEqual(TranslationAPISettings.effectiveProvider(provider, hasCredential: false), .apple)
            XCTAssertEqual(TranslationAPISettings.effectiveProvider(provider, hasCredential: true), provider)
        }
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
