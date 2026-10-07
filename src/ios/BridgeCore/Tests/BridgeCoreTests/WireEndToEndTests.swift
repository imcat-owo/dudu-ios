import Foundation
import XCTest

@testable import BridgeCore

/// 线级端到端：真宿主起来 → 原始 HTTP 按 MCP 协议走完整流程
/// （建会话 → 工具清单只有「搜」「命令」→「搜」找到假工具 →
/// 「命令」执行回清洗后的结果 → 自动路由 → 未知工具报错）。
///
/// 为什么不用官方 SDK Client 做这一组：SDK 0.12.1 的 HTTPClientTransport
/// 在 Linux 上把整段 SSE 响应体当作单条消息投递，客户端解码失败，
/// initialize 的响应被丢弃、connect 永远挂起（源码 + 实测坐实，
/// 见 Docs/kernel-recheck-0.12.1.md）。iOS/macOS 走流式逐事件路径不受影响；
/// SDK Client 版端到端在 HostEndToEndTests（仅非 Linux 平台编译）。
final class WireEndToEndTests: XCTestCase {
    private var harness: BridgeTestHarness!

    override func setUp() async throws {
        harness = try await BridgeTestHarness()
    }

    override func tearDown() async throws {
        await harness.shutdown()
        harness = nil
    }

    private func headers(session: String? = nil) -> [(String, String)] {
        var result: [(String, String)] = [
            ("Host", "127.0.0.1:\(harness.port)"),
            ("Accept", "application/json, text/event-stream"),
            ("Content-Type", "application/json"),
        ]
        if let session {
            result.append(("Mcp-Session-Id", session))
        }
        return result
    }

    /// 从 SSE 响应体里取出最后一条非空 data 的 JSON 对象。
    private func lastMessageObject(in sseBody: String) throws -> [String: Any] {
        let payloads = sseBody.components(separatedBy: "\n")
            .filter { $0.hasPrefix("data: ") }
            .map { String($0.dropFirst("data: ".count)) }
            .filter { !$0.isEmpty }
        let last = try XCTUnwrap(payloads.last, "SSE 响应里没有消息事件：\(sseBody)")
        let object = try JSONSerialization.jsonObject(
            with: Data(last.utf8))
        return try XCTUnwrap(object as? [String: Any], "消息不是 JSON 对象：\(last)")
    }

    private func resultObject(of message: [String: Any]) throws -> [String: Any] {
        try XCTUnwrap(message["result"] as? [String: Any], "消息里没有 result：\(message)")
    }

    private func firstContentText(of message: [String: Any]) throws -> String {
        let result = try resultObject(of: message)
        let content = try XCTUnwrap(
            result["content"] as? [[String: Any]], "result 里没有 content")
        let first = try XCTUnwrap(content.first, "content 为空")
        return try XCTUnwrap(first["text"] as? String, "content[0] 没有 text")
    }

    func testFullFlowOverWire() throws {
        let client = RawHTTPClient(port: harness.port)
        try client.connect()
        defer { client.close() }

        // 1. 建会话
        try client.sendRequest(
            method: "POST", path: "/mcp", headers: headers(),
            body: #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"wire-e2e","version":"1.0"}}}"#)
        let initResponse = try client.readResponse()
        XCTAssertEqual(initResponse.statusCode, 200)
        let sessionID = try XCTUnwrap(initResponse.header("Mcp-Session-Id"))
        let initMessage = try lastMessageObject(in: initResponse.body)
        let serverInfo = try XCTUnwrap(
            resultObject(of: initMessage)["serverInfo"] as? [String: Any])
        XCTAssertEqual(serverInfo["name"] as? String, "bridge")

        // 2. 初始化完成通知
        try client.sendRequest(
            method: "POST", path: "/mcp", headers: headers(session: sessionID),
            body: #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#)
        XCTAssertEqual(try client.readResponse().statusCode, 202)

        // 3. 工具清单只有「搜」「命令」
        try client.sendRequest(
            method: "POST", path: "/mcp", headers: headers(session: sessionID),
            body: #"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#)
        let listResponse = try client.readResponse()
        XCTAssertEqual(listResponse.statusCode, 200)
        let listMessage = try lastMessageObject(in: listResponse.body)
        let tools = try XCTUnwrap(
            resultObject(of: listMessage)["tools"] as? [[String: Any]])
        XCTAssertEqual(Set(tools.compactMap { $0["name"] as? String }), ["搜", "命令"])

        // 4. 「搜」找到回声工具
        try client.sendRequest(
            method: "POST", path: "/mcp", headers: headers(session: sessionID),
            body: #"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"搜","arguments":{"query":"回声"}}}"#)
        let searchMessage = try lastMessageObject(
            in: client.readResponse().body)
        let searchText = try firstContentText(of: searchMessage)
        XCTAssertTrue(searchText.contains("echo"), "搜应找到 echo：\(searchText)")
        XCTAssertTrue(searchText.contains("回声"))

        // 5. 「命令」点名执行回声，结果原样回来
        try client.sendRequest(
            method: "POST", path: "/mcp", headers: headers(session: sessionID),
            body: #"{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"命令","arguments":{"instruction":"复述这句话","tool":"echo","arguments":{"text":"端到端你好"}}}}"#)
        let echoMessage = try lastMessageObject(
            in: client.readResponse().body)
        XCTAssertEqual(try firstContentText(of: echoMessage), "端到端你好")

        // 6. 「命令」不点名，管家按指令自动路由到报时工具
        try client.sendRequest(
            method: "POST", path: "/mcp", headers: headers(session: sessionID),
            body: #"{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"命令","arguments":{"instruction":"现在几点"}}}"#)
        let routedMessage = try lastMessageObject(
            in: client.readResponse().body)
        XCTAssertTrue(
            try firstContentText(of: routedMessage).contains("现在是"))

        // 7. 「命令」执行噪音工具：回来的是清洗后的结果
        try client.sendRequest(
            method: "POST", path: "/mcp", headers: headers(session: sessionID),
            body: #"{"jsonrpc":"2.0","id":6,"method":"tools/call","params":{"name":"命令","arguments":{"instruction":"制造噪音","tool":"noise"}}}"#)
        let noiseMessage = try lastMessageObject(
            in: client.readResponse().body)
        let noiseText = try firstContentText(of: noiseMessage)
        XCTAssertTrue(
            noiseText.contains("进度 50%（重复 5 次）"),
            "重复行应被折叠计数：\(noiseText)")
        XCTAssertFalse(noiseText.contains("internalNote"), "内部字段应被清洗掉")
        XCTAssertFalse(noiseText.contains("debugTrace"), "内部字段应被清洗掉")
        XCTAssertFalse(noiseText.contains("\u{1B}"), "ANSI 转义应被清洗掉")

        // 8. 「命令」点名不存在的内部工具 → 管家失败，isError 且点名是哪个工具
        try client.sendRequest(
            method: "POST", path: "/mcp", headers: headers(session: sessionID),
            body: #"{"jsonrpc":"2.0","id":7,"method":"tools/call","params":{"name":"命令","arguments":{"instruction":"随便","tool":"不存在的工具"}}}"#)
        let unknownMessage = try lastMessageObject(
            in: client.readResponse().body)
        let unknownResult = try resultObject(of: unknownMessage)
        XCTAssertEqual(unknownResult["isError"] as? Bool, true)
        XCTAssertTrue(
            try firstContentText(of: unknownMessage).contains("不存在的工具"))

        // 9. MCP 层直接调未知工具名 → isError 且说明对外只有「搜」「命令」
        try client.sendRequest(
            method: "POST", path: "/mcp", headers: headers(session: sessionID),
            body: #"{"jsonrpc":"2.0","id":8,"method":"tools/call","params":{"name":"不存在的工具","arguments":{}}}"#)
        let metaUnknownMessage = try lastMessageObject(
            in: client.readResponse().body)
        let metaUnknownResult = try resultObject(of: metaUnknownMessage)
        XCTAssertEqual(metaUnknownResult["isError"] as? Bool, true)
        XCTAssertTrue(
            try firstContentText(of: metaUnknownMessage).contains("只提供"))
    }
}
