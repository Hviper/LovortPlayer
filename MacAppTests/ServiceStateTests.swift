import XCTest
@testable import LovortMacSubtitleService

final class ServiceStateTests: XCTestCase {

    func testAllServiceStates() {
        let states = ServiceStatus.allCases
        XCTAssertEqual(states.count, 5)

        XCTAssertEqual(ServiceStatus.uninstalled.rawValue, "未安装")
        XCTAssertEqual(ServiceStatus.stopped.rawValue, "已停止")
        XCTAssertEqual(ServiceStatus.starting.rawValue, "启动中")
        XCTAssertEqual(ServiceStatus.running.rawValue, "运行中")
        XCTAssertEqual(ServiceStatus.error.rawValue, "异常")
    }

    func testPrimaryActionTitles() {
        XCTAssertEqual(ServiceStatus.uninstalled.primaryActionTitle, "一键配置环境")
        XCTAssertEqual(ServiceStatus.stopped.primaryActionTitle, "启动服务")
        XCTAssertEqual(ServiceStatus.starting.primaryActionTitle, "正在启动...")
        XCTAssertEqual(ServiceStatus.running.primaryActionTitle, "停止服务")
        XCTAssertEqual(ServiceStatus.error.primaryActionTitle, "重新启动")
    }

    func testActionEnabledStates() {
        XCTAssertTrue(ServiceStatus.uninstalled.isActionEnabled)
        XCTAssertTrue(ServiceStatus.stopped.isActionEnabled)
        XCTAssertFalse(ServiceStatus.starting.isActionEnabled)
        XCTAssertTrue(ServiceStatus.running.isActionEnabled)
        XCTAssertTrue(ServiceStatus.error.isActionEnabled)
    }

    func testSymbolsDefined() {
        for state in ServiceStatus.allCases {
            XCTAssertFalse(state.sfSymbol.isEmpty)
            XCTAssertFalse(state.menuBarSymbol.isEmpty)
        }
    }
}
