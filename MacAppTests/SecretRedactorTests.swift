import XCTest
@testable import LovortMacSubtitleService

final class SecretRedactorTests: XCTestCase {

    func testRedactAccessTokenLine() {
        let redactor = SecretRedactor()
        let line = "Access token: secret_test_token_12345"
        let sanitized = redactor.redact(line)

        XCTAssertFalse(sanitized.contains("secret_test_token_12345"))
        XCTAssertTrue(sanitized.contains("[已隐藏口令 / REDACTED]"))
    }

    func testRedactHttpHeader() {
        let redactor = SecretRedactor()
        let line = "Incoming header: X-Lovort-Token: my-auth-token-xyz"
        let sanitized = redactor.redact(line)

        XCTAssertFalse(sanitized.contains("my-auth-token-xyz"))
        XCTAssertTrue(sanitized.contains("X-Lovort-Token: [REDACTED]"))
    }

    func testRedactQueryParam() {
        let redactor = SecretRedactor()
        let line = "GET /transcribe?token=abcde12345&lang=zh HTTP/1.1"
        let sanitized = redactor.redact(line)

        XCTAssertFalse(sanitized.contains("abcde12345"))
        XCTAssertTrue(sanitized.contains("?token=[REDACTED]"))
    }

    func testRedactBearerAuthorizationHeader() {
        let redactor = SecretRedactor()
        let sanitized = redactor.redact("Authorization: Bearer super-secret-bearer")

        XCTAssertFalse(sanitized.contains("super-secret-bearer"))
        XCTAssertEqual(sanitized, "Authorization: Bearer [REDACTED]")
    }

    func testRedactJsonTokenValue() {
        let redactor = SecretRedactor()
        let sanitized = redactor.redact(#"{"token":"json-secret","status":"ok"}"#)

        XCTAssertFalse(sanitized.contains("json-secret"))
        XCTAssertTrue(sanitized.contains(#""token":"[REDACTED]""#))
    }

    func testRedactKnownSecrets() {
        let secret = "dummy-unique-secret-key-9988"
        let redactor = SecretRedactor(knownSecrets: [secret])
        let line = "Failed request containing \(secret) inside body"
        let sanitized = redactor.redact(line)

        XCTAssertFalse(sanitized.contains(secret))
        XCTAssertTrue(sanitized.contains("[REDACTED]"))
    }

    func testMaskSecretForUI() {
        let preview = SecretRedactor.maskSecret("short-token")
        XCTAssertFalse(preview.contains("short-token"))
        XCTAssertTrue(preview.allSatisfy { $0 == "•" })
        XCTAssertGreaterThanOrEqual(preview.count, 8)
    }

    func testNonSensitiveLogRemainsUnchanged() {
        let redactor = SecretRedactor()
        let line = "Mac subtitle service listening on 0.0.0.0:8765"
        let sanitized = redactor.redact(line)

        XCTAssertEqual(sanitized, line)
    }
}
