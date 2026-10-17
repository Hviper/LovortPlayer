import XCTest
@testable import LovortMacSubtitleService

final class NetworkManagerTests: XCTestCase {

    func testFormatServiceURL() {
        let url = NetworkManager.formatServiceURL(ip: "192.168.1.120", port: 8765)
        XCTAssertEqual(url, "http://192.168.1.120:8765")
    }

    func testFormatServiceURLWithoutIP() {
        let url = NetworkManager.formatServiceURL(ip: nil, port: 8765)
        XCTAssertEqual(url, "未连接局域网")
    }

    func testFormatHostPort() {
        let hostPort = NetworkManager.formatHostPort(ip: "192.168.1.120", port: 8765)
        XCTAssertEqual(hostPort, "192.168.1.120:8765")
    }

    func testFormatHostPortWithoutIP() {
        let hostPort = NetworkManager.formatHostPort(ip: nil, port: 8765)
        XCTAssertEqual(hostPort, "127.0.0.1:8765")
    }
}
