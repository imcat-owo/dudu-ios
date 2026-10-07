// 本文件仅在非 Linux 平台编译：SDK 0.12.1 的 HTTPClientTransport 在 Linux 上
// 把整段 SSE 响应体当作单条消息投递，客户端解码失败、connect 无法完成
// （源码 + 实测坐实，见 BridgeCore/Docs/kernel-recheck-0.12.1.md）。
// Linux 上的同等端到端覆盖由 WireEndToEndTests（原始 HTTP 全流程）承担；
// 本组在 macOS 上照常运行，验证官方 Client 与桥的真实互通。
#if !os(Linux)

import Foundation
import MCP
import XCTest

@testable import BridgeCore

/// 端到端：真宿主起来 → SDK 官方 Client 经真实 HTTP 连入 →
/// 只看见「搜」「命令」→「搜」找到假工具 →「命令」执行回清洗后结果；
/// 多会话并发不串话。
final class HostEndToEndTests: XCTestCase {
    private var harness: BridgeTestHarness!

    override func setUp() async throws {
        harness = try await BridgeTestHarness()
    }

    override func tearDown() async throws {
        await harness.shutdown()
        harness = nil
    }

    private func makeClient() -> Client {
        Client(name: "e2e-client", version: "1.0")
    }

    private func endpointURL() -> URL {
        URL(string: "http://127.0.0.1:\(harness.port)/mcp")!
    }

    func testFullFlowSearchThenCommand() async throws {
        let client = makeClient()
        let transport = HTTPClientTransport(endpoint: endpointURL())
        let initializeResult = try await client.connect(transport: transport)
        XCTAssertEqual(initializeResult.serverInfo.name, "bridge")

        let (tools, _) = try await client.listTools()
        XCTAssertEqual(
            Set(tools.map(\.name)), [BridgeMetaTools.searchName, BridgeMetaTools.commandName],
            "对外必须只有「搜」和「命令」两个工具")

        let (searchContent, searchIsError) = try await client.callTool(
            name: BridgeMetaTools.searchName, arguments: ["query": .string("回声")])
        XCTAssertEqual(searchIsError, false)
        let searchText = toolText(searchContent)
        XCTAssertTrue(searchText.contains(FakeTools.echoName), "搜应找到 echo：\(searchText)")
        XCTAssertTrue(searchText.contains("回声"))

        let (commandContent, commandIsError) = try await client.callTool(
            name: BridgeMetaTools.commandName,
            arguments: [
                "instruction": .string("复述这句话"),
                "tool": .string(FakeTools.echoName),
                "arguments": .object(["text": .string("端到端你好")]),
            ])
        XCTAssertEqual(commandIsError, false)
        XCTAssertEqual(toolText(commandContent), "端到端你好")

        // 不点名：管家按指令智能路由到报时工具
        let (routedContent, routedIsError) = try await client.callTool(
            name: BridgeMetaTools.commandName,
            arguments: ["instruction": .string("现在几点")])
        XCTAssertEqual(routedIsError, false)
        XCTAssertTrue(toolText(routedContent).contains("现在是"))

        // 噪声工具：回来的必须是清洗后的
        let (noiseContent, noiseIsError) = try await client.callTool(
            name: BridgeMetaTools.commandName,
            arguments: [
                "instruction": .string("执行"),
                "tool": .string(FakeTools.noiseName),
            ])
        XCTAssertEqual(noiseIsError, false)
        let noiseText = toolText(noiseContent)
        XCTAssertFalse(noiseText.contains("internalNote"))
        XCTAssertTrue(noiseText.contains("进度 50%（重复 5 次）"))

        // 未知工具名：明确报错，不假装
        let (unknownContent, unknownIsError) = try await client.callTool(
            name: "不存在的工具", arguments: [:])
        XCTAssertEqual(unknownIsError, true)
        XCTAssertTrue(toolText(unknownContent).contains("只提供"))

        await client.disconnect()
    }

    func testConcurrentSessionsDoNotCrossTalk() async throws {
        let texts = (0..<6).map { "隔离标记-\($0)-\(UUID().uuidString)" }
        let endpoint = endpointURL()
        try await withThrowingTaskGroup(of: Void.self) { group in
            for expected in texts {
                group.addTask {
                    let client = Client(name: "iso-client", version: "1.0")
                    let transport = HTTPClientTransport(endpoint: endpoint)
                    _ = try await client.connect(transport: transport)
                    let (content, isError) = try await client.callTool(
                        name: BridgeMetaTools.commandName,
                        arguments: [
                            "instruction": .string("复述"),
                            "tool": .string(FakeTools.echoName),
                            "arguments": .object(["text": .string(expected)]),
                        ])
                    XCTAssertEqual(isError, false)
                    XCTAssertEqual(toolText(content), expected, "会话之间不许串话")
                    await client.disconnect()
                }
            }
            try await group.waitForAll()
        }
        let count = await harness.sessionManager.activeSessionCount
        XCTAssertEqual(count, 6, "六个客户端应各自持有一台独立会话（Server 不共享）")
        // 注：SDK 0.12.1 的客户端 disconnect 不发 DELETE（源码复核坐实），
        // 会话靠闲置回收收尾，回收行为在 SessionManagerTests 里单独验。
    }
}


/// 从工具结果内容里抽纯文本（文件级函数：并发测试的 @Sendable 闭包里不能抓测试实例）。
func toolText(_ content: [Tool.Content]) -> String {
    content.compactMap { item -> String? in
        if case .text(let text, _, _) = item { return text }
        return nil
    }.joined()
}

#endif
