import Foundation
import MCP

/// MCP 会话工厂与路由（桥的会话层）。
///
/// 铁律（零件审计 01）：
/// - 一台 SDK `Server` 一生只接一次 initialize —— 每会话新建 Server +
///   `StatefulHTTPServerTransport`，绝不做全局单例 Server；
/// - Stateless 传输禁用（上游 issue #254/#255 的串话/挂死未修），代码里只出现 Stateful；
/// - 校验走显式 Standard 流水线，本机模式 = localhost 名单，Origin/Host
///   校验不许整段关掉（SDK 有 `.disabled`，桥不用）。
public actor MCPSessionManager {
    public struct Configuration: Sendable {
        /// 会话闲置多久回收（秒）。
        public var idleTimeoutSeconds: TimeInterval
        /// 回收巡查间隔（秒）。
        public var reapIntervalSeconds: TimeInterval

        public init(idleTimeoutSeconds: TimeInterval = 3600, reapIntervalSeconds: TimeInterval = 60) {
            self.idleTimeoutSeconds = idleTimeoutSeconds
            self.reapIntervalSeconds = reapIntervalSeconds
        }
    }

    private struct Session {
        let server: Server
        let transport: StatefulHTTPServerTransport
        var lastAccessedAt: Date
    }

    /// 预生成会话 id 并交给传输层：这样 initialize 到达前宿主就知道会话 id，
    /// 路由与登记都确定。校验恒真——id 由桥自己生成（UUID），不可预测。
    private final class FixedSessionIDGenerator: SessionIDGenerator, @unchecked Sendable {
        private let id: String

        init(id: String) {
            self.id = id
        }

        func generateSessionID() -> String { id }
        func validateSessionID(_ sessionID: String) -> Bool { true }
    }

    private let registry: ToolRegistry
    private let steward: Steward
    private let configuration: Configuration
    private let now: @Sendable () -> Date
    private var sessions: [String: Session] = [:]
    private var reaperTask: Task<Void, Never>?

    public init(
        registry: ToolRegistry,
        steward: Steward,
        configuration: Configuration = Configuration(),
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.registry = registry
        self.steward = steward
        self.configuration = configuration
        self.now = now
    }

    public var activeSessionCount: Int {
        sessions.count
    }

    /// 启动闲置回收巡查（宿主启动后调用一次）。
    public func startReaper() {
        guard reaperTask == nil else { return }
        let interval = configuration.reapIntervalSeconds
        reaperTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(nanoseconds: UInt64(max(interval, 1) * 1_000_000_000))
                } catch {
                    return
                }
                await self?.reapIdleSessions()
            }
        }
    }

    /// 关停：回收线程停掉，所有会话逐个 stop。
    public func shutdown() async {
        reaperTask?.cancel()
        reaperTask = nil
        let all = sessions
        sessions.removeAll()
        for (_, session) in all {
            await session.server.stop()
        }
    }

    /// 回收闲置超时的会话（巡查与单测共用入口）。
    public func reapIdleSessions() async {
        let cutoff = now().addingTimeInterval(-configuration.idleTimeoutSeconds)
        let staleIDs = sessions.filter { $0.value.lastAccessedAt < cutoff }.map(\.key)
        for id in staleIDs {
            if let session = sessions.removeValue(forKey: id) {
                await session.server.stop()
            }
        }
    }

    // MARK: - 路由

    /// 一次 HTTP 请求的完整路由（宿主把解析好的 SDK HTTPRequest 交进来）：
    /// - 带已知会话头 → 转发该会话（DELETE 成功后摘除并停服）；
    /// - 带未知会话头 → 404；
    /// - 无会话头 → 只认 initialize 开新会话，其余 400。
    public func handle(request: HTTPRequest) async -> HTTPResponse {
        if let sessionID = request.header("Mcp-Session-Id") {
            guard let session = sessions[sessionID] else {
                return .error(
                    statusCode: 404,
                    MCPError.invalidRequest("Not Found: Session not found or expired"))
            }
            sessions[sessionID]?.lastAccessedAt = now()
            let response = await session.transport.handleRequest(request)
            if request.method.uppercased() == "DELETE", response.statusCode == 200 {
                sessions.removeValue(forKey: sessionID)
                await session.server.stop()
            }
            return response
        }
        guard Self.isInitializeRequest(request) else {
            return .error(
                statusCode: 400,
                MCPError.invalidRequest("Bad Request: Missing Mcp-Session-Id header"))
        }
        return await createSessionAndHandle(request: request)
    }

    private func createSessionAndHandle(request: HTTPRequest) async -> HTTPResponse {
        let newSessionID = UUID().uuidString
        let transport = StatefulHTTPServerTransport(
            sessionIDGenerator: FixedSessionIDGenerator(id: newSessionID),
            validationPipeline: Self.localValidationPipeline())
        let server = await BridgeMetaTools.makeServer(registry: registry, steward: steward)
        do {
            try await server.start(transport: transport)
        } catch {
            return .error(
                statusCode: 500,
                MCPError.internalError("Bridge session start failed: \(error)"))
        }
        sessions[newSessionID] = Session(
            server: server, transport: transport, lastAccessedAt: now())
        let response = await transport.handleRequest(request)
        if case .error = response {
            sessions.removeValue(forKey: newSessionID)
            await server.stop()
        }
        return response
    }

    /// 路由层只做「是不是 initialize」的窥探（自己的 JSONSerialization，
    /// 先守卫顶层对象）；协议本体一律由 SDK 传输层处理，桥不自创协议判断。
    static func isInitializeRequest(_ request: HTTPRequest) -> Bool {
        guard request.method.uppercased() == "POST", let body = request.body else {
            return false
        }
        guard let object = try? StrictJSON.parseObject(body) else { return false }
        if object.string("method") == "initialize" {
            return true
        }
        // JSON-RPC 批量请求里含 initialize 也算。
        return false
    }

    /// 本机模式校验流水线：Origin/Host 只认 localhost 家族。
    /// 将来局域网模式换名单项即可，结构不动、校验不关。
    static func localValidationPipeline() -> StandardValidationPipeline {
        StandardValidationPipeline(validators: [
            OriginValidator.localhost(),
            AcceptHeaderValidator(mode: .sseRequired),
            ContentTypeValidator(),
            ProtocolVersionValidator(),
            SessionValidator(),
        ])
    }
}
