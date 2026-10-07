import Foundation
import BridgeCore

/// 「桥」小管家内核在 App 侧的组装点（合并第 16 条：内核搬入）。
///
/// 只负责按依赖顺序造出三件套：工具注册中心 → 小管家 → 会话管理，
/// 并把设备能力工具组（第 19 条，DeviceTools）、联网搜索工具
/// （第 18 条，WebSearchBridgeTool，桥审计 B）与报问题工具（第 21 条，
/// ReportIssueTool，需注入 steward 取活动任务）挂进注册中心——注册是
/// 异步的（注册中心是 actor），组装时起一个任务完成；单次失败自动重试
/// （最多 3 次，间隔 1s/2s），重试前先清掉上次注册到一半的残留；仍失败
/// 则状态置 failed，设置页会明确提示并给重试按钮，不再显示假"运行中"。
/// 对外入口（CF 中转/局域网）开启是第 17、18 条的事，不在这里。
/// 本类目前只被对外服务（BridgeExternalMCPService）在用户于设置页
/// 开启时构造，App 现有行为零变化。

/// 工具注册状态（设置页展示用）：注册中 / 就绪 / 失败（带原因）。
public enum BridgeToolRegistrationState: Sendable, Equatable {
    case registering
    case ready
    case failed(String)
}

final class BridgeKernelAssembly {
    let registry: ToolRegistry
    let steward: Steward
    let sessionManager: MCPSessionManager

    private static let logger = AppLogger(category: "BridgeAssembly")

    /// 注册重试参数：最多 3 次，两次等待间隔 1s、2s。
    private static let maxRegisterAttempts = 3
    private static let registerRetryDelays: [UInt64] = [1_000_000_000, 2_000_000_000]

    private let stateLock = NSLock()
    private var _registrationState: BridgeToolRegistrationState = .registering

    // MARK: - MCP 聚合点（[mcp-agg]）

    /// 她接入的 MCP 工具聚合器（actor，工具清单缓存归它管）。
    private let mcpAggregator = MCPAggregator()

    /// 当前由聚合器管理的工具 `[聚合名: 指纹]`（stateLock 保护）。
    private var mcpManagedTools: [String: String] = [:]

    /// servers.json 变化观察者（设置页/CLI/add_mcp 改动 → 2s 去抖重聚合）。
    private var mcpObserveTask: Task<Void, Never>?

    /// 当前工具注册状态（线程安全读）。
    var toolRegistrationState: BridgeToolRegistrationState {
        stateLock.withLock { _registrationState }
    }

    init() {
        let registry = ToolRegistry()
        self.registry = registry
        // 敏感审批门：敏感工具执行前走手机侧弹框请主人确认，
        // 外部 AI 传进来的任何标记都不被信任（用户-P1）。
        // [T-bridge-kill] 硬停钩子：主人打断/取消在跑任务时，直杀桥会话
        // 里沙箱命令的进程组（只停桥这一条，不碰 Swift 任务取消的主路径；
        // 坐标层 execute 的取消 handler 是更精准的主路径，这里是兜底）。
        let steward = Steward(
            registry: registry,
            approvalGate: StewardSensitiveApprovalGate(),
            hardStopHook: {
                ISHExecutionCoordinator.stopAllNonisolated(sessionId: OffloadToolRunner.bridgeSessionId)
            }
        )
        self.steward = steward
        self.sessionManager = MCPSessionManager(registry: registry, steward: steward)

        Task { await self.registerToolsWithRetry() }
        startMCPObserveTask()
    }

    deinit {
        mcpObserveTask?.cancel()
    }

    /// 带重试的工具注册。每次重试前先注销已注册的工具名，保证
    /// "上次注册到一半"不会以 duplicateName 堵死重试。
    private func registerToolsWithRetry() async {
        var deviceError: Error?
        for attempt in 1...Self.maxRegisterAttempts {
            for name in DeviceTools.toolNames {
                _ = await registry.unregister(name: name)
            }
            do {
                try await DeviceTools.registerAll(into: registry)
                deviceError = nil
                break
            } catch {
                deviceError = error
                Self.logger.error("设备能力工具注册失败（第 \(attempt) 次）：\(error)")
                if attempt < Self.maxRegisterAttempts {
                    try? await Task.sleep(nanoseconds: Self.registerRetryDelays[attempt - 1])
                }
            }
        }
        if let deviceError {
            stateLock.withLock {
                // 注意：用插值拿 CustomStringConvertible 的中文描述；
                // localizedDescription 对 Swift 原生 Error 只给系统英文套话。
                _registrationState = .failed("设备能力工具注册失败：\(deviceError)")
            }
            return
        }

        var reportError: Error?
        for attempt in 1...Self.maxRegisterAttempts {
            _ = await registry.unregister(name: ReportIssueTool.toolName)
            do {
                // 报问题工具（第 21 条）需要 steward 取「当时在忙什么」，
                // 不走 DeviceTools 的无依赖注册路径，单独在这里挂。
                try await ReportIssueTool.register(into: registry, steward: steward)
                reportError = nil
                break
            } catch {
                reportError = error
                Self.logger.error("报问题工具注册失败（第 \(attempt) 次）：\(error)")
                if attempt < Self.maxRegisterAttempts {
                    try? await Task.sleep(nanoseconds: Self.registerRetryDelays[attempt - 1])
                }
            }
        }
        if let reportError {
            stateLock.withLock {
                _registrationState = .failed("报问题工具注册失败：\(reportError)")
            }
            return
        }

        var searchError: Error?
        for attempt in 1...Self.maxRegisterAttempts {
            _ = await registry.unregister(name: WebSearchBridgeTool.toolName)
            do {
                // 联网搜索工具（第 18 条，桥审计 B）：无依赖，单独挂。
                // 没配 key 时工具照常注册，调用时诚实报错指引去设置页填 key。
                try await WebSearchBridgeTool.register(into: registry)
                searchError = nil
                break
            } catch {
                searchError = error
                Self.logger.error("联网搜索工具注册失败（第 \(attempt) 次）：\(error)")
                if attempt < Self.maxRegisterAttempts {
                    try? await Task.sleep(nanoseconds: Self.registerRetryDelays[attempt - 1])
                }
            }
        }
        if let searchError {
            stateLock.withLock {
                _registrationState = .failed("联网搜索工具注册失败：\(searchError)")
            }
            return
        }
        // MCP 聚合点：她接入并启用的 MCP 工具进注册表（搜/命令两口）。
        // 单次尝试、永不拖垮整组注册：沙箱没启动、某家连不上都只记日志，
        // servers.json 下次变化（或设置页手动重试）时再同步。
        let managed = await mcpAggregator.sync(
            into: registry,
            previouslyManaged: stateLock.withLock { mcpManagedTools })
        stateLock.withLock { mcpManagedTools = managed }

        stateLock.withLock { _registrationState = .ready }
    }

    /// 设置页"重试"按钮用：只在失败态重跑（就绪态重跑会撞重复注册名，
    /// 注册中则说明已经在跑了，都直接返回）。
    func retryToolRegistration() {
        let shouldRun = stateLock.withLock { () -> Bool in
            guard case .failed = _registrationState else { return false }
            _registrationState = .registering
            return true
        }
        guard shouldRun else { return }
        Task { await self.registerToolsWithRetry() }
    }

    // MARK: - MCP 聚合重同步（[mcp-agg]）

    /// servers.json 变化观察：去抖 2s 后重聚合。首个值是订阅时的
    /// 当前快照，跳过（初始同步已在 registerToolsWithRetry 里做过）。
    private func startMCPObserveTask() {
        mcpObserveTask = Task { @MainActor [weak self] in
            var isFirst = true
            for await _ in MCPStore.shared.$servers.values {
                if isFirst { isFirst = false; continue }
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                guard !Task.isCancelled else { return }
                await self?.resyncMCPAggregation()
            }
        }
    }

    /// MCP 聚合重同步（add_mcp / remove_mcp / toggle_mcp / 设置页改动后调）。
    /// 服务未运行时（assembly 为 nil）调用方直接无操作；单 server 失败
    /// 不影响其他 server。
    func resyncMCPAggregation() async {
        let managed = await mcpAggregator.sync(
            into: registry,
            previouslyManaged: stateLock.withLock { mcpManagedTools })
        stateLock.withLock { mcpManagedTools = managed }
    }

    // MARK: - 主人打断（第 20 条）

    /// 小管家当前在跑/排队的任务（设置页展示「正在干什么」用）。
    func activeStewardTasks() async -> [StewardTaskSummary] {
        await steward.activeTaskSummaries()
    }

    /// 主人打断：停掉在跑与排队的全部任务。每个被打断的任务都会以
    /// 「主人打断」专属文案收尾回给正在等结果的外部 AI；同时逐个写进
    /// 跨会话共享事件日志（刺 3），其他会话能看到主人打断过外部任务。
    @discardableResult
    func interruptStewardTasksByOwner() async -> [StewardTaskSummary] {
        let tasks = await steward.activeTaskSummaries()
        for task in tasks {
            await steward.interruptByOwner(task.id)
            let instruction = String(task.instruction.prefix(80))
            // 注：task.id 是任务 UUID，不是会话 id，不往事件的 session
            // 字段里填；任务归属在 summary 的工具/指令里已说明。
            SharedEventLog.shared.emit(
                event: "bridge.task_interrupted",
                summary: "主人打断了小管家任务（工具：\(task.toolName ?? "未定")，指令：\(instruction)）")
        }
        return tasks
    }
}
