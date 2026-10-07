import XCTest

@testable import BridgeCore

final class ProviderTests: XCTestCase {
    private var server: FakeProviderServer!
    private var baseURL: String!

    override func setUp() async throws {
        server = FakeProviderServer()
        let port = try server.start()
        baseURL = "http://127.0.0.1:\(port)/v1"
    }

    override func tearDown() async throws {
        server.stop()
        server = nil
    }

    private func makeClient(
        keys: [ProviderKey] = [ProviderKey(secret: "key-1")],
        customHeaders: [HeaderField] = [],
        customBodyJSON: String? = nil,
        isEnabled: Bool = true,
        baseURL overrideBaseURL: String? = nil
    ) -> OpenAICompatibleClient {
        OpenAICompatibleClient(
            configuration: ProviderConfiguration(
                name: "假服务商",
                baseURL: overrideBaseURL ?? baseURL,
                model: "fake-model",
                keys: keys,
                customHeaders: customHeaders,
                customBodyJSON: customBodyJSON,
                isEnabled: isEnabled))
    }

    private static let chatResponse = """
        {"id":"chatcmpl-fake","object":"chat.completion","choices":[{"index":0,"message":{"role":"assistant","content":"你好，我是假上游"},"finish_reason":"stop"}],"usage":{"total_tokens":3}}
        """

    func testChatCompletionAssemblesRequest() async throws {
        server.setResponse(status: 200, body: Self.chatResponse)
        let client = makeClient(
            customHeaders: [HeaderField(name: "X-Custom", value: "bridge-test")],
            customBodyJSON: #"{"temperature":0.7,"model":"forged"}"#)
        let content = try await client.chatCompletion(
            messages: [ChatMessage(role: "user", content: "你好")])
        XCTAssertEqual(content, "你好，我是假上游")

        XCTAssertEqual(server.requests.count, 1)
        let request = try XCTUnwrap(server.requests.first)
        XCTAssertEqual(request.method, "POST")
        XCTAssertEqual(request.uri, "/v1/chat/completions")
        XCTAssertEqual(request.header("Authorization"), "Bearer key-1")
        XCTAssertEqual(request.header("X-Custom"), "bridge-test")
        XCTAssertTrue(request.header("Content-Type")?.contains("application/json") ?? false)

        let body = try StrictJSON.parseObject(request.body)
        XCTAssertEqual(body.string("model"), "fake-model", "配置的模型优先于自定义请求体里的同名字段")
        XCTAssertEqual(body.double("temperature") ?? 0, 0.7, accuracy: 0.0001)
        let messages = try XCTUnwrap(body.array("messages"))
        XCTAssertEqual(messages.count, 1)
        let first = try XCTUnwrap(messages.first as? [String: Any])
        XCTAssertEqual(first["content"] as? String, "你好")
    }

    func testRoundRobinAcrossKeys() async throws {
        server.setResponse(status: 200, body: Self.chatResponse)
        let client = makeClient(keys: [ProviderKey(secret: "k1"), ProviderKey(secret: "k2")])
        _ = try await client.chatCompletion(messages: [ChatMessage(role: "user", content: "一")])
        _ = try await client.chatCompletion(messages: [ChatMessage(role: "user", content: "二")])
        XCTAssertEqual(server.requests.count, 2)
        XCTAssertEqual(server.requests[0].header("Authorization"), "Bearer k1")
        XCTAssertEqual(server.requests[1].header("Authorization"), "Bearer k2")
    }

    func testUpstreamErrorPassthroughAndCooldown() async throws {
        server.setResponse(status: 401, body: #"{"error":{"message":"invalid api key"}}"#)
        let client = makeClient()
        do {
            _ = try await client.chatCompletion(messages: [ChatMessage(role: "user", content: "hi")])
            XCTFail("401 应抛错")
        } catch let error as ProviderError {
            guard case .upstream(let status, let body) = error else {
                return XCTFail("应是 upstream 错误，实际：\(error)")
            }
            XCTAssertEqual(status, 401)
            XCTAssertTrue(body.contains("invalid api key"), "上游原文必须透传：\(body)")
        }
        // 唯一一把密钥已进冷却 → 下一次连请求都发不出
        let snapshot = await client.keyPool.snapshot()
        XCTAssertNotNil(snapshot.first?.cooldownUntil)
        do {
            _ = try await client.chatCompletion(messages: [ChatMessage(role: "user", content: "hi")])
            XCTFail("无可用密钥应抛错")
        } catch let error as ProviderError {
            guard case .noAvailableKey = error else {
                return XCTFail("应是 noAvailableKey，实际：\(error)")
            }
        }
        XCTAssertEqual(server.requests.count, 1, "第二次不应真的发出请求")
    }

    func testPingSuccessAndFailure() async throws {
        server.setResponse(status: 200, body: "{}")
        let client = makeClient()
        let result = try await client.ping()
        XCTAssertEqual(result.statusCode, 200)
        XCTAssertGreaterThanOrEqual(result.latencySeconds, 0)
        XCTAssertEqual(server.requests.first?.uri, "/v1/models")
        XCTAssertEqual(server.requests.first?.method, "GET")

        server.setResponse(status: 500, body: "server boom")
        do {
            _ = try await client.ping()
            XCTFail("500 应抛错")
        } catch let error as ProviderError {
            guard case .upstream(let status, let body) = error else {
                return XCTFail("应是 upstream 错误，实际：\(error)")
            }
            XCTAssertEqual(status, 500)
            XCTAssertEqual(body, "server boom")
        }
    }

    func testInvalidCustomBodyIsLocatable() async throws {
        let client = makeClient(customBodyJSON: #"{"a": }"#)
        do {
            _ = try await client.chatCompletion(messages: [ChatMessage(role: "user", content: "hi")])
            XCTFail("坏请求体应抛错")
        } catch let error as ProviderError {
            guard case .invalidCustomBody(let detail) = error else {
                return XCTFail("应是 invalidCustomBody，实际：\(error)")
            }
            XCTAssertTrue(detail.contains("第 6 个字符"), "错误必须能定位：\(detail)")
        } catch {
            XCTFail("不应抛其他错误：\(error)")
        }
    }

    func testCustomBodyTopLevelArrayRejected() async throws {
        let client = makeClient(customBodyJSON: "[1,2]")
        do {
            _ = try await client.chatCompletion(messages: [ChatMessage(role: "user", content: "hi")])
            XCTFail("顶层数组应抛错")
        } catch let error as ProviderError {
            guard case .invalidCustomBody(let detail) = error else {
                return XCTFail("应是 invalidCustomBody，实际：\(error)")
            }
            XCTAssertTrue(detail.contains("顶层"))
        } catch {
            XCTFail("不应抛其他错误：\(error)")
        }
    }

    func testInvalidBaseURL() async throws {
        let client = makeClient(baseURL: "ftp://example.com/v1")
        do {
            _ = try await client.ping()
            XCTFail("非法 BaseURL 应抛错")
        } catch let error as ProviderError {
            guard case .invalidBaseURL = error else {
                return XCTFail("应是 invalidBaseURL，实际：\(error)")
            }
        } catch {
            XCTFail("不应抛其他错误：\(error)")
        }
    }

    func testDisabledProvider() async throws {
        let client = makeClient(isEnabled: false)
        do {
            _ = try await client.chatCompletion(messages: [ChatMessage(role: "user", content: "hi")])
            XCTFail("停用服务商应抛错")
        } catch let error as ProviderError {
            guard case .providerDisabled = error else {
                return XCTFail("应是 providerDisabled，实际：\(error)")
            }
        } catch {
            XCTFail("不应抛其他错误：\(error)")
        }
    }
}

final class KeyPoolTests: XCTestCase {
    private final class ClockBox: @unchecked Sendable {
        var now = Date(timeIntervalSince1970: 1_000_000)
    }

    func testCooldownSkipsAndRecovers() async {
        let clock = ClockBox()
        let keyA = ProviderKey(secret: "a")
        let keyB = ProviderKey(secret: "b")
        let pool = KeyPool(
            keys: [keyA, keyB], failureThreshold: 1, cooldownSeconds: 60,
            now: { clock.now })

        let first = await pool.nextKey()
        XCTAssertEqual(first?.secret, "a")
        await pool.markFailure(keyID: keyA.id)
        let second = await pool.nextKey()
        XCTAssertEqual(second?.secret, "b", "a 冷却中应跳过")
        let third = await pool.nextKey()
        XCTAssertEqual(third?.secret, "b")
        await pool.markFailure(keyID: keyB.id)
        let none = await pool.nextKey()
        XCTAssertNil(none, "两把都冷却时应无可用密钥")
        clock.now = clock.now.addingTimeInterval(61)
        let recovered = await pool.nextKey()
        XCTAssertNotNil(recovered, "冷却到期应恢复可用")
    }

    func testFailureThreshold() async {
        let clock = ClockBox()
        let key = ProviderKey(secret: "only")
        let pool = KeyPool(
            keys: [key], failureThreshold: 2, cooldownSeconds: 60,
            now: { clock.now })
        await pool.markFailure(keyID: key.id)
        let stillUsable = await pool.nextKey()
        XCTAssertNotNil(stillUsable, "没到阈值不进冷却")
        await pool.markFailure(keyID: key.id)
        let cooled = await pool.nextKey()
        XCTAssertNil(cooled, "到阈值进冷却")
        await pool.markSuccess(keyID: key.id)
        let afterSuccess = await pool.nextKey()
        XCTAssertNotNil(afterSuccess, "成功一次解除冷却")
    }

    func testDisabledKeySkipped() async {
        let pool = KeyPool(keys: [
            ProviderKey(secret: "off", isEnabled: false),
            ProviderKey(secret: "on"),
        ])
        let key = await pool.nextKey()
        XCTAssertEqual(key?.secret, "on")
    }
}
