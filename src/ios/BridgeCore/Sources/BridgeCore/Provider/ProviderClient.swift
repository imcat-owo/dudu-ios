import Foundation

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

/// 服务商层的错误：上游报错原文透传（状态码 + 响应体），不包装不吞。
public enum ProviderError: Error, CustomStringConvertible {
    case providerDisabled(name: String)
    case noAvailableKey(provider: String)
    case invalidBaseURL(String)
    /// 自定义请求体不合法，detail 带第一个语法错误的位置。
    case invalidCustomBody(detail: String)
    /// 传输层失败，带原始错误描述。
    case transportFailed(String)
    /// 上游返回非 2xx：状态码与响应原文整段带回。
    case upstream(status: Int, body: String)
    /// 2xx 但响应结构不符合 OpenAI 兼容格式，带关键信息。
    case malformedResponse(String)

    public var description: String {
        switch self {
        case .providerDisabled(let name):
            return "服务商已停用：\(name)"
        case .noAvailableKey(let provider):
            return "服务商 \(provider) 没有可用密钥（全部停用或冷却中）"
        case .invalidBaseURL(let value):
            return "BaseURL 不合法：\(value)"
        case .invalidCustomBody(let detail):
            return "自定义请求体不合法：\(detail)"
        case .transportFailed(let detail):
            return "请求传输失败：\(detail)"
        case .upstream(let status, let body):
            return "上游返回 \(status)：\(body)"
        case .malformedResponse(let detail):
            return "上游响应结构异常：\(detail)"
        }
    }
}

/// 传输抽象：真实走 URLSession；单测可注入替身或指向进程内假服务器。
public protocol ProviderHTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

public struct URLSessionProviderTransport: ProviderHTTPTransport {
    public init() {}

    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw ProviderError.transportFailed("响应不是 HTTP 响应：\(response)")
        }
        return (data, http)
    }
}

public struct ChatMessage: Sendable, Equatable {
    public var role: String
    public var content: String

    public init(role: String, content: String) {
        self.role = role
        self.content = content
    }
}

public struct ProviderPingResult: Sendable, Equatable {
    public var statusCode: Int
    public var latencySeconds: TimeInterval

    public init(statusCode: Int, latencySeconds: TimeInterval) {
        self.statusCode = statusCode
        self.latencySeconds = latencySeconds
    }
}

/// OpenAI 兼容接口客户端（骨架）：请求组装、密钥轮换与冷却、
/// Ping 连通性测试都在这里；本步不连任何真实外部服务。
public struct OpenAICompatibleClient: Sendable {
    public let configuration: ProviderConfiguration
    public let keyPool: KeyPool
    private let transport: any ProviderHTTPTransport

    public init(
        configuration: ProviderConfiguration,
        transport: any ProviderHTTPTransport = URLSessionProviderTransport()
    ) {
        self.configuration = configuration
        self.keyPool = KeyPool(keys: configuration.keys)
        self.transport = transport
    }

    // MARK: - Ping

    /// 连通性测试：GET {base}/models。成功回状态码与延迟；
    /// 失败按传输错误/上游原文抛回，绝不假装连通。
    public func ping() async throws -> ProviderPingResult {
        try ensureEnabled()
        let key = try await acquireKey()
        var request = URLRequest(url: try configuration.endpointURL("models"))
        request.httpMethod = "GET"
        applyHeaders(to: &request, key: key, isJSONBody: false)
        let started = Date()
        let (data, response) = try await send(request)
        let latency = Date().timeIntervalSince(started)
        guard (200..<300).contains(response.statusCode) else {
            await keyPool.markFailure(keyID: key.id)
            throw ProviderError.upstream(
                status: response.statusCode, body: Self.bodyText(data))
        }
        await keyPool.markSuccess(keyID: key.id)
        return ProviderPingResult(statusCode: response.statusCode, latencySeconds: latency)
    }

    // MARK: - Chat

    /// 发一轮对话补全，返回助手文本。组装规则：
    /// 自定义请求体作为底，桥的 model/messages 覆盖同名字段（配置为准）；
    /// Authorization 与 Content-Type 由桥强制写入，自定义请求头改不动这两项。
    public func chatCompletion(messages: [ChatMessage]) async throws -> String {
        try ensureEnabled()
        let key = try await acquireKey()

        var body: [String: Any] = [:]
        if let custom = configuration.customBodyJSON,
            !custom.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            body = try Self.parseCustomBody(custom).raw
        }
        body["model"] = configuration.model
        body["messages"] = messages.map { ["role": $0.role, "content": $0.content] }

        var request = URLRequest(url: try configuration.endpointURL("chat/completions"))
        request.httpMethod = "POST"
        request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        applyHeaders(to: &request, key: key, isJSONBody: true)

        let (data, response) = try await send(request)
        guard (200..<300).contains(response.statusCode) else {
            await keyPool.markFailure(keyID: key.id)
            throw ProviderError.upstream(
                status: response.statusCode, body: Self.bodyText(data))
        }
        await keyPool.markSuccess(keyID: key.id)
        return try Self.extractContent(from: data)
    }

    // MARK: - 内部

    private func ensureEnabled() throws {
        guard configuration.isEnabled else {
            throw ProviderError.providerDisabled(name: configuration.name)
        }
    }

    private func acquireKey() async throws -> ProviderKey {
        guard let key = await keyPool.nextKey() else {
            throw ProviderError.noAvailableKey(provider: configuration.name)
        }
        return key
    }

    private func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        do {
            return try await transport.send(request)
        } catch let error as ProviderError {
            throw error
        } catch {
            throw ProviderError.transportFailed(error.localizedDescription)
        }
    }

    private func applyHeaders(to request: inout URLRequest, key: ProviderKey, isJSONBody: Bool) {
        for header in configuration.customHeaders {
            let lowered = header.name.lowercased()
            // 这两项由桥掌管，自定义请求头不许覆盖（写在配置里会被忽略）。
            guard lowered != "authorization", lowered != "content-type" else { continue }
            request.setValue(header.value, forHTTPHeaderField: header.name)
        }
        request.setValue("Bearer \(key.secret)", forHTTPHeaderField: "Authorization")
        if isJSONBody {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
    }

    /// 严格解析自定义请求体；出错时把第一个语法错误的位置带出来。
    public static func parseCustomBody(_ text: String) throws -> StrictJSONObject {
        do {
            return try StrictJSON.parseObject(text)
        } catch let error as StrictJSONError {
            if let offset = StrictJSON.firstSyntaxErrorOffset(text) {
                throw ProviderError.invalidCustomBody(
                    detail: "\(error.description)；第一个语法错误在第 \(offset) 个字符处")
            }
            throw ProviderError.invalidCustomBody(detail: error.description)
        }
    }

    /// 从 chat/completions 响应里取 choices[0].message.content，全程严格解析。
    public static func extractContent(from data: Data) throws -> String {
        let root: StrictJSONObject
        do {
            root = try StrictJSON.parseObject(data)
        } catch {
            throw ProviderError.malformedResponse("响应不是 JSON 对象：\(error)")
        }
        guard let choices = root.array("choices"),
            let first = choices.first as? [String: Any]
        else {
            throw ProviderError.malformedResponse("缺少 choices 数组")
        }
        let firstObject = StrictJSONObject(raw: first)
        guard let message = firstObject.object("message"),
            let content = message.string("content")
        else {
            throw ProviderError.malformedResponse("choices[0].message.content 缺失或非字符串")
        }
        return content
    }

    private static func bodyText(_ data: Data) -> String {
        String(data: data, encoding: .utf8) ?? "<非 UTF-8 响应体，\(data.count) 字节>"
    }
}
