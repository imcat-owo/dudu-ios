import XCTest
@testable import BridgeCore

/// 地基骨架的占位单测：证明测试框架可运行、内核门面的元信息与定稿一致。
final class BridgeKernelTests: XCTestCase {
    func testDisplayName() {
        XCTAssertEqual(BridgeKernel.displayName, "桥")
    }

    func testSDKVersionMatchesPinnedRelease() {
        XCTAssertEqual(BridgeKernel.sdkVersion, "0.12.1")
    }

    func testServerName() {
        XCTAssertEqual(BridgeKernel.serverName, "bridge")
    }
}
