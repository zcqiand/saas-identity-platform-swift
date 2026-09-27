import XCTest

/// 门禁冒烟：证明「本仓工作树 → home-mac → swift test」链路是通的。
/// 业务测试随需求走 red-first（先红后绿），不在这里预写。
final class CoreKitSmokeTests: XCTestCase {
    func testRemoteGateChainWorks() {
        XCTAssertTrue(true)
    }
}
