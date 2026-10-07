import Foundation
import BridgeCore

/// App 对外 MCP 服务（合并第 17 条）：把「搜」+「命令」两个元工具的 MCP
/// server 接入 App 对外服务。
///
/// - 内核的 `MCPSessionManager` 每会话新建一台 `BridgeMetaTools.makeServer`
///   造的 Server，对外永远只有「搜」「命令」两个工具，本类只负责把它
///   经现成的 `BridgeHTTPHost`（NIO，监听 127.0.0.1、系统分配端口）挂进 App；
/// - 默认关闭。App 启动时绝不自动 start——只有设置页的用户动作才调
///   `ensureRunning()`，App 现有行为零变化；
/// - 每次 `ensureRunning()` 都新建三件套与宿主（宿主 stop 后 NIO 线程组已
///   优雅关闭、不可复用），停止时连同全部会话一并关停。
///
/// API 合约（设置页只用这五个，签名不要改）：
/// `BridgeExternalMCPService.shared`、`isRunning`、`boundPort`、
/// `ensureRunning() throws`、`stop()`。
public final class BridgeExternalMCPService: @unchecked Sendable {

    public struct Configuration: Sendable {
        /// 监听地址。默认 `127.0.0.1`（本机模式）。
        /// 以后局域网副路可配 `0.0.0.0` 再启动；注意会话管理器的校验名单
        /// 现在只放 localhost 家族，名单放行不在本类的职责内。
        public var bindHost: String
        /// 监听端口。0 = 系统分配，实际值读 `boundPort`。
        public var port: Int

        public init(bindHost: String = "127.0.0.1", port: Int = 0) {
            self.bindHost = bindHost
            self.port = port
        }
    }

    public static let shared = BridgeExternalMCPService()

    /// 下次 `ensureRunning()` 才生效的配置；运行中修改不影响已启动的宿主。
    public var configuration = Configuration()

    private let lock = NSLock()
    private var assembly: BridgeKernelAssembly?
    private var host: BridgeHTTPHost?

    init() {}

    /// 是否正在对外服务。
    public var isRunning: Bool {
        lock.withLock { host != nil }
    }

    /// 实际绑定的端口（`ensureRunning()` 成功后有效，未运行为 nil）。
    public var boundPort: Int? {
        lock.withLock { host?.boundPort }
    }

    /// 确保对外服务已启动。已在运行则直接返回（幂等）。
    /// 绑定失败抛宿主的 `BridgeHTTPHost.HostError`，不留半截状态。
    public func ensureRunning() throws {
        let snapshot = lock.withLock { (host, configuration) }
        if snapshot.0 != nil { return }

        let assembly = BridgeKernelAssembly()
        let newHost = BridgeHTTPHost(
            configuration: .init(host: snapshot.1.bindHost, port: snapshot.1.port),
            sessionManager: assembly.sessionManager)
        do {
            try newHost.start()
        } catch {
            // 绑定失败不留半截：把 NIO 线程组也关干净再把错误抛出去。
            newHost.stop()
            throw error
        }

        let kept = lock.withLock { () -> Bool in
            guard host == nil else { return false }
            self.assembly = assembly
            host = newHost
            return true
        }
        if !kept {
            // 极小概率有并发调用抢先绑了另一台：刚起的这台停掉，避免端口泄漏。
            newHost.stop()
        }
    }

    /// 停服：宿主关监听并断开现有连接，全部会话逐个关停。未运行则无操作。
    public func stop() {
        let current: (BridgeHTTPHost?, BridgeKernelAssembly?) = lock.withLock {
            let result = (host, assembly)
            host = nil
            assembly = nil
            return result
        }
        current.0?.stop()
        if let sessionManager = current.1?.sessionManager {
            Task { await sessionManager.shutdown() }
        }
    }

    // MARK: - 主人打断（第 20 条，设置页用）

    /// 小管家当前在跑/排队的任务；服务未运行时为空。
    public func activeStewardTasks() async -> [StewardTaskSummary] {
        let current: BridgeKernelAssembly? = lock.withLock { assembly }
        guard let current else { return [] }
        return await current.activeStewardTasks()
    }

    /// 主人打断小管家当前全部任务，返回被打断的任务数；未运行时为 0。
    @discardableResult
    public func interruptStewardTasksByOwner() async -> Int {
        let current: BridgeKernelAssembly? = lock.withLock { assembly }
        guard let current else { return 0 }
        return await current.interruptStewardTasksByOwner().count
    }

    // MARK: - 工具注册状态（批七 P2-4，设置页用）

    /// 桥工具注册状态；服务未运行时为 nil。
    public func toolRegistrationState() -> BridgeToolRegistrationState? {
        let current: BridgeKernelAssembly? = lock.withLock { assembly }
        return current?.toolRegistrationState
    }

    /// 工具注册失败后的手动重试；服务未运行或状态不是失败时无操作。
    public func retryToolRegistration() {
        let current: BridgeKernelAssembly? = lock.withLock { assembly }
        current?.retryToolRegistration()
    }

    // MARK: - MCP 聚合（[mcp-agg]，add_mcp/remove_mcp/toggle_mcp/设置页用）

    /// MCP 聚合重同步：把 MCPStore 当前状态对齐进小管家注册表；
    /// 服务未运行时无操作。
    public func resyncMCPTools() {
        let current: BridgeKernelAssembly? = lock.withLock { assembly }
        Task { await current?.resyncMCPAggregation() }
    }
}
