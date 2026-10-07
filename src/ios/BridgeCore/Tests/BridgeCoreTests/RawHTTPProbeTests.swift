import XCTest

@testable import BridgeCore

/// 协议探针：用原始 socket 逐条核 SDK 0.12.1 Stateful 传输在真实 HTTP 上的行为，
/// 结论写进 BridgeCore/Docs/kernel-recheck-0.12.1.md——这里的每个测试名
/// 就是复核文档里的一条证据。
final class RawHTTPProbeTests: XCTestCase {
    private var harness: BridgeTestHarness!

    override func setUp() async throws {
        harness = try await BridgeTestHarness()
    }

    override func tearDown() async throws {
        await harness.shutdown()
        harness = nil
    }

    // MARK: - 辅助

    private func makeClient() throws -> RawHTTPClient {
        let client = RawHTTPClient(port: harness.port)
        try client.connect()
        return client
    }

    private func headers(
        session: String? = nil,
        accept: String = "application/json, text/event-stream",
        contentType: String? = "application/json",
        // SDK 的 localhost 名单要求 Host 带数字端口（"127.0.0.1:*"），
        // 所以默认带上宿主实际端口；探针 12 故意传坏值不受此默认影响。
        host: String? = nil,
        extra: [(String, String)] = []
    ) -> [(String, String)] {
        var result: [(String, String)] = [
            ("Host", host ?? "127.0.0.1:\(harness.port)"),
            ("Accept", accept),
        ]
        if let contentType {
            result.append(("Content-Type", contentType))
        }
        if let session {
            result.append(("Mcp-Session-Id", session))
        }
        result.append(contentsOf: extra)
        return result
    }

    private static let initializeBody = """
        {"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"probe","version":"1.0"}}}
        """

    /// 开一个会话：initialize + initialized 通知，返回（会话 id, 已消耗的客户端）。
    private func openSession() throws -> (String, RawHTTPClient) {
        let client = try makeClient()
        try client.sendRequest(
            method: "POST", path: "/mcp", headers: headers(), body: Self.initializeBody)
        let response = try client.readResponse()
        XCTAssertEqual(response.statusCode, 200)
        let sessionID = try XCTUnwrap(
            response.header("Mcp-Session-Id"), "initialize 响应应带 Mcp-Session-Id")
        try client.sendRequest(
            method: "POST", path: "/mcp", headers: headers(session: sessionID),
            body: #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#)
        let accepted = try client.readResponse()
        XCTAssertEqual(accepted.statusCode, 202)
        return (sessionID, client)
    }

    // MARK: - 探针 1：POST 响应形状 + priming 在最前

    func testProbe01_InitializeIsSSEStreamWithPrimingFirst() throws {
        let client = try makeClient()
        try client.sendRequest(
            method: "POST", path: "/mcp", headers: headers(), body: Self.initializeBody)
        let response = try client.readResponse()
        XCTAssertEqual(response.statusCode, 200)
        XCTAssertTrue(
            response.header("Content-Type")?.contains("text/event-stream") ?? false,
            "POST 请求的响应应是 SSE 流，实际：\(response.header("Content-Type") ?? "无")")
        XCTAssertNotNil(response.header("Mcp-Session-Id"))

        // priming 事件 = data 为空的事件，且在 initialize 结果之前
        let primingRange = try XCTUnwrap(response.body.range(of: "data: \n\n"))
        let resultRange = try XCTUnwrap(response.body.range(of: "\"serverInfo\""))
        XCTAssertLessThan(
            primingRange.lowerBound, resultRange.lowerBound, "priming 应在结果之前到达")
        XCTAssertTrue(response.body.contains("\"name\":\"bridge\""))
        client.close()
    }

    // MARK: - 探针 2：会话内 tools/list 只有两个元工具

    func testProbe02_ToolsListShowsOnlyMetaTools() throws {
        let (sessionID, client) = try openSession()
        try client.sendRequest(
            method: "POST", path: "/mcp", headers: headers(session: sessionID),
            body: #"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#)
        let response = try client.readResponse()
        XCTAssertEqual(response.statusCode, 200)
        XCTAssertTrue(response.body.contains("搜"))
        XCTAssertTrue(response.body.contains("命令"))
        XCTAssertFalse(response.body.contains("echo"), "内部工具不许直接对外露出")
        client.close()
    }

    // MARK: - 探针 3/4：校验状态码

    func testProbe03_MissingSSEAcceptReturns406() throws {
        let client = try makeClient()
        try client.sendRequest(
            method: "POST", path: "/mcp",
            headers: headers(accept: "application/json"), body: Self.initializeBody)
        let response = try client.readResponse()
        XCTAssertEqual(response.statusCode, 406)
        client.close()
    }

    func testProbe04_WrongContentTypeReturns415() throws {
        let client = try makeClient()
        try client.sendRequest(
            method: "POST", path: "/mcp",
            headers: headers(contentType: "text/plain"), body: Self.initializeBody)
        let response = try client.readResponse()
        XCTAssertEqual(response.statusCode, 415)
        client.close()
    }

    // MARK: - 探针 5：伪造会话 id → 404（会话管理层）

    func testProbe05_FabricatedSessionReturns404() throws {
        let client = try makeClient()
        try client.sendRequest(
            method: "POST", path: "/mcp", headers: headers(session: "fabricated-id-123"),
            body: #"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#)
        let response = try client.readResponse()
        XCTAssertEqual(response.statusCode, 404)
        client.close()
    }

    // MARK: - 探针 6：其他方法 405 + Allow

    func testProbe06_UnsupportedMethodReturns405WithAllow() throws {
        let (sessionID, client) = try openSession()
        try client.sendRequest(
            method: "PUT", path: "/mcp", headers: headers(session: sessionID), body: "{}")
        let response = try client.readResponse()
        XCTAssertEqual(response.statusCode, 405)
        XCTAssertTrue(response.header("Allow")?.contains("POST") ?? false)
        client.close()
    }

    // MARK: - 探针 7：DELETE 关会话，之后 404

    func testProbe07_DeleteTerminatesSession() throws {
        let (sessionID, client) = try openSession()
        try client.sendRequest(
            method: "DELETE", path: "/mcp",
            headers: headers(session: sessionID, contentType: nil), body: nil)
        let deleteResponse = try client.readResponse()
        XCTAssertEqual(deleteResponse.statusCode, 200)
        XCTAssertTrue(deleteResponse.body.isEmpty, "DELETE 确认应是空体")

        try client.sendRequest(
            method: "POST", path: "/mcp", headers: headers(session: sessionID),
            body: #"{"jsonrpc":"2.0","id":3,"method":"tools/list"}"#)
        let after = try client.readResponse()
        XCTAssertEqual(after.statusCode, 404, "会话关掉后同 id 再来应 404")
        client.close()
    }

    // MARK: - 探针 8：同会话二次 initialize → 400

    func testProbe08_SecondInitializeReturns400() throws {
        let (sessionID, client) = try openSession()
        try client.sendRequest(
            method: "POST", path: "/mcp", headers: headers(session: sessionID),
            body: Self.initializeBody)
        let response = try client.readResponse()
        XCTAssertEqual(response.statusCode, 400)
        XCTAssertTrue(response.body.contains("already initialized"))
        client.close()
    }

    // MARK: - 探针 9：独立 GET 流先来 priming

    func testProbe09_StandaloneGETStreamStartsWithPriming() throws {
        let (sessionID, client) = try openSession()
        try client.sendRequest(
            method: "GET", path: "/mcp",
            headers: headers(session: sessionID, contentType: nil), body: nil)
        let raw = try client.readRawUntil(marker: "_GET_stream_")
        XCTAssertTrue(raw.contains("200"), "状态行应是 200：\(raw.prefix(100))")
        XCTAssertTrue(raw.contains("id: _GET_stream_"), "GET 流的 priming 事件 id 应以 _GET_stream_ 打头")
        client.close()
    }

    // MARK: - 探针 10：假的 Last-Event-ID → 400

    func testProbe10_BogusLastEventIDReturns400() throws {
        let (sessionID, client) = try openSession()
        try client.sendRequest(
            method: "GET", path: "/mcp",
            headers: headers(
                session: sessionID, contentType: nil,
                extra: [("Last-Event-ID", "bogus-999")]),
            body: nil)
        let response = try client.readResponse()
        XCTAssertEqual(response.statusCode, 400)
        XCTAssertTrue(response.body.contains("Invalid Last-Event-ID"))
        client.close()
    }

    // MARK: - 探针 11：断线后用 Last-Event-ID 续传回放

    func testProbe11_ResumeReplaysMissedEvent() throws {
        let (sessionID, client) = try openSession()
        // 发起一个要 1.2 秒的工具调用（JSON-RPC id = 7），只读到 priming 就断线
        try client.sendRequest(
            method: "POST", path: "/mcp", headers: headers(session: sessionID),
            body: """
                {"jsonrpc":"2.0","id":7,"method":"tools/call","params":{"name":"命令","arguments":{"instruction":"等一下","tool":"delay","arguments":{"ms":1200}}}}
                """)
        let raw = try client.readRawUntil(marker: "data: \n\n")
        // priming 事件 id 形如 "7_0"，从原文里摘出来（不硬编码计数）
        let idLineStart = try XCTUnwrap(raw.range(of: "id: "))
        let idLineEnd = try XCTUnwrap(raw.range(of: "\n", range: idLineStart.upperBound..<raw.endIndex))
        let primingID = String(raw[idLineStart.upperBound..<idLineEnd.lowerBound])
            .trimmingCharacters(in: .whitespaces)
        XCTAssertTrue(primingID.hasPrefix("7_"), "priming id 应以请求 id 打头：\(primingID)")
        client.close()

        // 等工具跑完、结果被传输层存下
        Thread.sleep(forTimeInterval: 1.8)

        let client2 = try makeClient()
        try client2.sendRequest(
            method: "GET", path: "/mcp",
            headers: headers(
                session: sessionID, contentType: nil,
                extra: [("Last-Event-ID", primingID)]),
            body: nil)
        let replayed = try client2.readRawUntil(marker: "已等待")
        XCTAssertTrue(
            replayed.contains("已等待 1200 毫秒"),
            "续传应回放断线期间产生的结果事件")
        client2.close()
    }

    // MARK: - 探针 12：坏 Host 头 → 421（本机校验名单）

    func testProbe12_ForeignHostHeaderReturns421() throws {
        let client = try makeClient()
        try client.sendRequest(
            method: "POST", path: "/mcp",
            headers: headers(host: "evil.example.com"), body: Self.initializeBody)
        let response = try client.readResponse()
        XCTAssertEqual(response.statusCode, 421)
        client.close()
    }

    // MARK: - 探针 13：错路径 → 404（宿主层）

    func testProbe13_WrongPathReturns404() throws {
        let client = try makeClient()
        try client.sendRequest(
            method: "POST", path: "/other", headers: headers(), body: Self.initializeBody)
        let response = try client.readResponse()
        XCTAssertEqual(response.statusCode, 404)
        client.close()
    }
}
