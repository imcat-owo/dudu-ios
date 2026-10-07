import Foundation
import MCP
import XCTest

@testable import BridgeCore

/// 会话管理器层面的路由与回收测试（不经 HTTP，直接喂 SDK 的 HTTPRequest）。
final class SessionManagerTests: XCTestCase {

    private func makeManager(idleTimeout: TimeInterval = 3600) async throws -> MCPSessionManager {
        let registry = ToolRegistry()
        try await FakeTools.registerAll(into: registry)
        return MCPSessionManager(
            registry: registry,
            steward: Steward(registry: registry),
            configuration: .init(idleTimeoutSeconds: idleTimeout, reapIntervalSeconds: 60))
    }

    private func initializeRequest() -> HTTPRequest {
        let body = """
            {"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"manager-test","version":"1.0"}}}
            """
        return HTTPRequest(
            method: "POST",
            headers: [
                "Accept": "application/json, text/event-stream",
                "Content-Type": "application/json",
                // SDK 的 localhost 名单是 "127.0.0.1:*" 模式：Host 必须带数字端口，
                // 裸地址会被回 421（源码 HTTPRequestValidation.matchesPattern）。
                "Host": "127.0.0.1:8080",
            ],
            body: Data(body.utf8),
            path: "/mcp")
    }

    private func sessionID(of response: HTTPResponse) -> String? {
        response.headers.first { $0.key.lowercased() == "mcp-session-id" }?.value
    }

    func testInitializeCreatesSession() async throws {
        let manager = try await makeManager()
        let response = await manager.handle(request: initializeRequest())
        XCTAssertEqual(response.statusCode, 200)
        XCTAssertNotNil(sessionID(of: response))
        let count = await manager.activeSessionCount
        XCTAssertEqual(count, 1)
        await manager.shutdown()
    }

    func testMissingSessionHeaderRejected() async throws {
        let manager = try await makeManager()
        let request = HTTPRequest(
            method: "POST",
            headers: ["Accept": "application/json, text/event-stream", "Content-Type": "application/json"],
            body: Data(#"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#.utf8),
            path: "/mcp")
        let response = await manager.handle(request: request)
        XCTAssertEqual(response.statusCode, 400)
        await manager.shutdown()
    }

    func testUnknownSessionReturns404() async throws {
        let manager = try await makeManager()
        let request = HTTPRequest(
            method: "POST",
            headers: [
                "Accept": "application/json, text/event-stream",
                "Content-Type": "application/json",
                "Mcp-Session-Id": "no-such-session",
            ],
            body: Data(#"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#.utf8),
            path: "/mcp")
        let response = await manager.handle(request: request)
        XCTAssertEqual(response.statusCode, 404)
        await manager.shutdown()
    }

    func testTwoSessionsGetDistinctIDs() async throws {
        let manager = try await makeManager()
        let first = await manager.handle(request: initializeRequest())
        let second = await manager.handle(request: initializeRequest())
        let firstID = sessionID(of: first)
        let secondID = sessionID(of: second)
        XCTAssertNotNil(firstID)
        XCTAssertNotNil(secondID)
        XCTAssertNotEqual(firstID, secondID)
        let count = await manager.activeSessionCount
        XCTAssertEqual(count, 2)
        await manager.shutdown()
    }

    func testIdleReaperCollectsSession() async throws {
        let manager = try await makeManager(idleTimeout: 0.3)
        let response = await manager.handle(request: initializeRequest())
        let id = try XCTUnwrap(sessionID(of: response))
        try await Task.sleep(nanoseconds: 500_000_000)
        await manager.reapIdleSessions()
        let count = await manager.activeSessionCount
        XCTAssertEqual(count, 0, "闲置超时会话应被回收")

        // 回收后同一个会话 id 再来 → 404
        let request = HTTPRequest(
            method: "POST",
            headers: [
                "Accept": "application/json, text/event-stream",
                "Content-Type": "application/json",
                "Mcp-Session-Id": id,
            ],
            body: Data(#"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#.utf8),
            path: "/mcp")
        let after = await manager.handle(request: request)
        XCTAssertEqual(after.statusCode, 404)
        await manager.shutdown()
    }
}
