import Foundation

@testable import BridgeCore

/// e2e 与探针共用的装配：注册中心（假工具）+ 管家 + 会话管理器 + 真宿主。
final class BridgeTestHarness {
    let registry: ToolRegistry
    let sessionManager: MCPSessionManager
    let host: BridgeHTTPHost
    let port: Int

    init() async throws {
        let registry = ToolRegistry()
        try await FakeTools.registerAll(into: registry)
        self.registry = registry
        let steward = Steward(registry: registry)
        let manager = MCPSessionManager(registry: registry, steward: steward)
        self.sessionManager = manager
        let host = BridgeHTTPHost(
            configuration: .init(host: "127.0.0.1", port: 0, endpoint: "/mcp"),
            sessionManager: manager)
        self.host = host
        try host.start()
        guard let boundPort = host.boundPort else {
            throw NSError(
                domain: "BridgeTestHarness", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "宿主启动后没有绑定端口"])
        }
        self.port = boundPort
    }

    func shutdown() async {
        host.stop()
        await sessionManager.shutdown()
    }
}
