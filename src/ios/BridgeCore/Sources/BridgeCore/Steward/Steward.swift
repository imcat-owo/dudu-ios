import Foundation

/// 管家任务状态机：排队 → 派发 → 执行 → 清洗 → 完成，
/// 异常分支：失败（带原因）/ 已取消 / 主人打断 / 超时熔断。终态不可再变。
/// 「主人打断」单列一态：它和一般取消的收尾动作相同（停任务），但回给
/// 外部调用方的文案必须能明确区分——外部 AI 收到后应先去问主人原因，
/// 而不是把打断当普通失败自行重试。
public enum StewardState: Sendable, Equatable {
    case queued
    case dispatched(toolName: String)
    case executing(toolName: String)
    case cleaning
    case finished
    case failed(reason: String)
    case cancelled
    case interruptedByOwner
    case timedOut

    public var isTerminal: Bool {
        switch self {
        case .finished, .failed, .cancelled, .interruptedByOwner, .timedOut:
            return true
        case .queued, .dispatched, .executing, .cleaning:
            return false
        }
    }
}

/// 一次「命令」的入参。
public struct StewardRequest: Sendable {
    /// 自然语言指令（未点名工具时，管家拿它去注册中心搜索路由）。
    public var instruction: String
    /// 点名的工具（外部 AI 经「搜」选定后可点名）；nil = 管家智能路由。
    public var toolName: String?
    /// 给工具的参数（严格 JSON 对象）。
    public var arguments: StrictJSONObject
    /// 超时熔断秒数。
    public var timeoutSeconds: Double

    public init(
        instruction: String,
        toolName: String? = nil,
        arguments: StrictJSONObject = StrictJSONObject(raw: [:]),
        timeoutSeconds: Double = 30
    ) {
        self.instruction = instruction
        self.toolName = toolName
        self.arguments = arguments
        self.timeoutSeconds = timeoutSeconds
    }
}

/// 任务结果：终态 + 实际用的工具 + 原文与清洗后文本（原文保留备查，
/// 对外只回清洗后的高密度结果）。
public struct StewardResult: Sendable, Equatable {
    public var id: UUID
    public var state: StewardState
    public var toolName: String?
    public var rawText: String?
    public var cleanedText: String?
    public var isError: Bool

    public init(
        id: UUID, state: StewardState, toolName: String?,
        rawText: String?, cleanedText: String?, isError: Bool
    ) {
        self.id = id
        self.state = state
        self.toolName = toolName
        self.rawText = rawText
        self.cleanedText = cleanedText
        self.isError = isError
    }
}

/// 一个未终结任务的摘要（宿主 UI 展示「小管家正在干什么」用）。
public struct StewardTaskSummary: Sendable, Equatable {
    public var id: UUID
    public var state: StewardState
    public var toolName: String?
    public var instruction: String

    public init(id: UUID, state: StewardState, toolName: String?, instruction: String) {
        self.id = id
        self.state = state
        self.toolName = toolName
        self.instruction = instruction
    }
}

/// 一个已终结任务的摘要（「报问题」附上下文用，AI-P1-4/AI-P2-7）。
/// 终结原因原文一起带上：主人报"刚才那个错"时，Issue 里有现场。
public struct StewardFinishedSummary: Sendable, Equatable {
    public var toolName: String?
    public var instruction: String
    public var state: StewardState
    /// 终结原因原文（失败的 reason / 超时与取消的文案）；成功时为 nil。
    public var errorText: String?

    public init(
        toolName: String?, instruction: String, state: StewardState, errorText: String?
    ) {
        self.toolName = toolName
        self.instruction = instruction
        self.state = state
        self.errorText = errorText
    }
}

/// 小管家调度：串行队列接单，逐个走完状态机。
///
/// - 队列：一台在跑时后面的排队，不并发抢工具；
/// - 取消：排队中的直接取消，运行中的取消其任务，收尾为 .cancelled；
///   主人在 App 里手动打断走 `interruptByOwner`，动作相同但收尾为
///   .interruptedByOwner 并回专属文案，让外部 AI 能区分并先来问主人；
/// - 超时熔断：执行与睡眠赛跑，先到者定性。熔断靠协作式取消——工具处理
///   函数必须响应 Task 取消（桥自己的工具都响应）；不理取消的工具会继续
///   占着队列直到自然结束，其结果被丢弃（这一条写死在语义里，不假装能强杀）。
/// - 错误：工具抛错/返回错误都收尾为 .failed，原因原文保留进结果，不吞。
public actor Steward {
    /// 「命令」超时熔断的上界（秒）。
    ///
    /// 外部 AI 传超大值（如 1e999 → Double.inf）时，Double→UInt64 越界转换
    /// 会直接 trap 崩进程——这里先钳住再转整数。「命令」入口
    /// （BridgeMetaTools）对超界值直接报错；这里是纵深防御，
    /// 直调 Steward.execute 的调用方同样被保护。
    public static let maxTimeoutSeconds: Double = 3600

    /// 把外部传进来的超时钳到 [0, maxTimeoutSeconds]；非有限值（inf/NaN）
    /// 按上界处理，绝不让它进 UInt64 转换。
    private static func clampedTimeout(_ raw: Double) -> Double {
        guard raw.isFinite else { return maxTimeoutSeconds }
        return min(max(raw, 0), maxTimeoutSeconds)
    }

    /// 主人打断时回给外部调用方的文案。与一般取消（「任务已取消」）、
    /// 超时、失败明确区分：点明是主人在 App 里手动打断，并要求外部 AI
    /// 先向主人询问原因、不许自行重试。
    public static let ownerInterruptedText =
        "【主人打断】这次任务被主人在 App 里手动打断，已经停止。主人可能有新的安排或对执行方式不满意；请先向主人询问打断的原因和下一步，不要把这当成普通失败自行重试。"

    private let registry: ToolRegistry
    private let cleaner: ResultCleaner

    private var queue: [UUID] = []
    private var requests: [UUID: StewardRequest] = [:]
    private var results: [UUID: StewardResult] = [:]
    private var histories: [UUID: [StewardState]] = [:]
    /// 终结顺序（新的在尾）：recentFinishedSummaries 按它倒序取。
    /// finish() 里 requests[id] 会被清掉，所以指令快照另存一份。
    private var finishedOrder: [UUID] = []
    private var finishedInstructions: [UUID: String] = [:]
    private var waiters: [UUID: [CheckedContinuation<StewardResult, Never>]] = [:]
    private var runningID: UUID?
    private var runningTask: Task<Void, Never>?
    private var cancelRequested: Set<UUID> = []
    private var ownerInterruptRequested: Set<UUID> = []

    /// 敏感审批门（宿主 App 注入）：敏感工具执行前走它请主人在手机上确认。
    /// nil = 没装门，敏感工具一律拒绝（默认安全）。
    private let approvalGate: (any SensitiveApprovalGate)?

    /// 运行中任务被取消/打断时的"硬停"钩子（宿主 App 注入）：直接杀底层
    /// 执行资源（如 iSH 沙箱里的进程组）。nil = 没装钩子，只靠 Swift
    /// 任务取消传播。钩子在 runningTask?.cancel() 之后调——取消传播是主
    /// 路径，钩子是兜底（任务若卡在不响应取消的环节，进程不会自己停）；
    /// 两者都幂等（重复杀已死的进程组无害）。
    private let hardStopHook: (@Sendable () -> Void)?

    public init(
        registry: ToolRegistry,
        cleaner: ResultCleaner = ResultCleaner(),
        approvalGate: (any SensitiveApprovalGate)? = nil,
        hardStopHook: (@Sendable () -> Void)? = nil
    ) {
        self.registry = registry
        self.cleaner = cleaner
        self.approvalGate = approvalGate
        self.hardStopHook = hardStopHook
    }

    // MARK: - 提交与查询

    @discardableResult
    public func submit(_ request: StewardRequest) -> UUID {
        let id = UUID()
        requests[id] = request
        finishedInstructions[id] = request.instruction
        let initial = StewardResult(
            id: id, state: .queued, toolName: request.toolName,
            rawText: nil, cleanedText: nil, isError: false)
        results[id] = initial
        histories[id] = [.queued]
        queue.append(id)
        startNextIfIdle()
        return id
    }

    public func state(of id: UUID) -> StewardState? {
        results[id]?.state
    }

    public func result(of id: UUID) -> StewardResult? {
        results[id]
    }

    /// 任务的完整状态变迁史（审计日志的雏形：谁在何时走到哪一步都可查）。
    public func stateHistory(of id: UUID) -> [StewardState] {
        histories[id] ?? []
    }

    public func waitForCompletion(_ id: UUID) async -> StewardResult {
        if let result = results[id], result.state.isTerminal {
            return result
        }
        return await withCheckedContinuation { continuation in
            waiters[id, default: []].append(continuation)
        }
    }

    /// 提交并等到终态，一步到位的便捷口（元工具「命令」走这里）。
    public func execute(_ request: StewardRequest) async -> StewardResult {
        let id = submit(request)
        return await waitForCompletion(id)
    }

    /// 取消任务：排队中的立刻收尾；运行中的标记并取消其任务，由运行流程收尾。
    /// [T-bridge-kill] 运行中的任务还会走 hardStopHook 显式硬停底层进程
    /// （取消传播是主路径，钩子是兜底——卡在不响应取消环节的进程不会自己停）。
    public func cancel(_ id: UUID) {
        guard let result = results[id], !result.state.isTerminal else { return }
        cancelRequested.insert(id)
        if runningID == id {
            runningTask?.cancel()
            hardStopHook?()
        } else if queue.contains(id) {
            queue.removeAll { $0 == id }
            finish(
                id: id, state: .cancelled, toolName: result.toolName,
                rawText: nil, cleanedText: "任务已取消", isError: true)
        }
    }

    /// 主人打断（App 内主人手动触发）：停任务的动作与 `cancel` 相同，
    /// 但终态是 `.interruptedByOwner`、回给外部调用方的是
    /// `ownerInterruptedText`，与一般取消/超时/失败明确区分。
    /// [T-bridge-kill] 同 cancel，运行中的任务走 hardStopHook 显式硬停
    /// 底层进程；终态语义不变（`.interruptedByOwner`，外部 AI 照样收到
    /// "主人打断"报错），只是沙箱里的进程也真停。
    public func interruptByOwner(_ id: UUID) {
        guard let result = results[id], !result.state.isTerminal else { return }
        ownerInterruptRequested.insert(id)
        if runningID == id {
            runningTask?.cancel()
            hardStopHook?()
        } else if queue.contains(id) {
            queue.removeAll { $0 == id }
            finish(
                id: id, state: .interruptedByOwner, toolName: result.toolName,
                rawText: nil, cleanedText: Self.ownerInterruptedText, isError: true)
        }
    }

    /// 当前未终结的任务摘要：正在跑的在前，排队的按提交顺序。
    /// 宿主（App 设置页）靠它展示「小管家正在干什么」并提供打断入口。
    public func activeTaskSummaries() -> [StewardTaskSummary] {
        var ids: [UUID] = []
        if let runningID, results[runningID]?.state.isTerminal == false {
            ids.append(runningID)
        }
        ids.append(contentsOf: queue)
        return ids.compactMap { id in
            guard let result = results[id], !result.state.isTerminal else { return nil }
            return StewardTaskSummary(
                id: id, state: result.state, toolName: result.toolName,
                instruction: requests[id]?.instruction ?? "")
        }
    }

    /// 最近终结的任务摘要（新的在前）：供「报问题」附上下文用。
    /// 成功的不带报错文本；失败/超时/取消/主人打断带原因原文。
    public func recentFinishedSummaries(limit: Int = 5) -> [StewardFinishedSummary] {
        finishedOrder.suffix(max(limit, 0)).reversed().compactMap { id in
            guard let result = results[id], result.state.isTerminal else { return nil }
            let errorText: String? = switch result.state {
            case .finished: nil
            case .failed(let reason): reason
            case .timedOut, .cancelled, .interruptedByOwner: result.cleanedText
            default: result.cleanedText
            }
            return StewardFinishedSummary(
                toolName: result.toolName,
                instruction: finishedInstructions[id] ?? "",
                state: result.state,
                errorText: errorText)
        }
    }

    // MARK: - 内部流程

    private func startNextIfIdle() {
        guard runningID == nil, let next = queue.first else { return }
        queue.removeFirst()
        runningID = next
        guard let request = requests[next] else {
            runningID = nil
            return
        }
        runningTask = Task { [weak self] in
            await self?.run(id: next, request: request)
        }
    }

    private func run(id: UUID, request: StewardRequest) async {
        // —— 派发：定工具 ——
        let toolName: String
        if let explicit = request.toolName {
            toolName = explicit
        } else if let hit = await registry.search(request.instruction).first {
            toolName = hit.name
        } else {
            let reason = "找不到能处理这条指令的工具：\(request.instruction)"
            finish(
                id: id, state: .failed(reason: reason), toolName: nil,
                rawText: nil, cleanedText: reason, isError: true)
            completeRun(id: id)
            return
        }
        transition(id: id, to: .dispatched(toolName: toolName))

        // —— 派发校验：在册、启用、敏感权限 ——
        guard let descriptor = await registry.descriptor(for: toolName) else {
            let reason = "工具未在册：\(toolName)"
            finish(
                id: id, state: .failed(reason: reason), toolName: toolName,
                rawText: nil, cleanedText: reason, isError: true)
            completeRun(id: id)
            return
        }
        guard descriptor.isEnabled else {
            let reason = "工具已停用：\(toolName)"
            finish(
                id: id, state: .failed(reason: reason), toolName: toolName,
                rawText: nil, cleanedText: reason, isError: true)
            completeRun(id: id)
            return
        }
        // —— 敏感审批：只能由手机侧签发，外部传进来的标记一律不认 ——
        if descriptor.permission == .sensitive {
            let decision =
                await approvalGate?.requestApproval(
                    toolName: toolName, instruction: request.instruction) ?? .denied
            switch decision {
            case .approved:
                break
            case .denied:
                let reason =
                    "工具 \(toolName) 是敏感操作，需要主人在手机上确认后才能执行；未获批准，已拒绝"
                finish(
                    id: id, state: .failed(reason: reason), toolName: toolName,
                    rawText: nil, cleanedText: reason, isError: true)
                completeRun(id: id)
                return
            case .ownerAway:
                let reason = "主人未在手机旁，已拒绝"
                finish(
                    id: id, state: .failed(reason: reason), toolName: toolName,
                    rawText: nil, cleanedText: reason, isError: true)
                completeRun(id: id)
                return
            }
        }

        // 主人若在派发阶段就打断了（运行任务已被 cancel，但派发校验是
        // 同步走完的），别再进执行段，直接按主人打断收尾。
        if ownerInterruptRequested.contains(id) {
            finish(
                id: id, state: .interruptedByOwner, toolName: toolName,
                rawText: nil, cleanedText: Self.ownerInterruptedText, isError: true)
            completeRun(id: id)
            return
        }

        // —— 执行（带超时熔断）——
        transition(id: id, to: .executing(toolName: toolName))
        let outcome = await executeWithTimeout(toolName: toolName, request: request)

        // 主人打断优先于一般取消定性：两者都会取消运行任务，但回给
        // 外部调用方的文案必须能区分（主人打断要让对方先来问主人）。
        if ownerInterruptRequested.contains(id) {
            finish(
                id: id, state: .interruptedByOwner, toolName: toolName,
                rawText: nil, cleanedText: Self.ownerInterruptedText, isError: true)
            completeRun(id: id)
            return
        }

        if cancelRequested.contains(id) {
            finish(
                id: id, state: .cancelled, toolName: toolName,
                rawText: nil, cleanedText: "任务已取消", isError: true)
            completeRun(id: id)
            return
        }

        switch outcome {
        case .output(let output) where !output.isError:
            transition(id: id, to: .cleaning)
            let cleaned = cleaner.clean(output.text)
            finish(
                id: id, state: .finished, toolName: toolName,
                rawText: output.text, cleanedText: cleaned, isError: false)
        case .output(let output):
            finish(
                id: id, state: .failed(reason: output.text), toolName: toolName,
                rawText: output.text, cleanedText: output.text, isError: true)
        case .threw(let message):
            finish(
                id: id, state: .failed(reason: message), toolName: toolName,
                rawText: nil, cleanedText: message, isError: true)
        case .timedOut:
            let message = "执行超时（超过 \(request.timeoutSeconds) 秒），已熔断"
            finish(
                id: id, state: .timedOut, toolName: toolName,
                rawText: nil, cleanedText: message, isError: true)
        case .cancelled:
            finish(
                id: id, state: .cancelled, toolName: toolName,
                rawText: nil, cleanedText: "任务已取消", isError: true)
        }
        completeRun(id: id)
    }

    private enum ExecutionOutcome: Sendable {
        case output(ToolOutput)
        case threw(String)
        case timedOut
        case cancelled
    }

    private func executeWithTimeout(
        toolName: String, request: StewardRequest
    ) async -> ExecutionOutcome {
        let registry = self.registry
        let arguments = request.arguments
        // 先钳制再转 UInt64：超大值（inf/NaN/1e19+）直接转整数会 trap 崩进程。
        let timeout = Self.clampedTimeout(request.timeoutSeconds)
        return await withTaskGroup(of: ExecutionOutcome.self) { group in
            group.addTask {
                do {
                    let output = try await registry.invoke(name: toolName, arguments: arguments)
                    return .output(output)
                } catch is CancellationError {
                    return .cancelled
                } catch {
                    return .threw(String(describing: error))
                }
            }
            group.addTask {
                do {
                    try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                    return .timedOut
                } catch {
                    return .cancelled
                }
            }
            let first = await group.next() ?? .threw("执行组没有产出结果")
            group.cancelAll()
            return first
        }
    }

    private func transition(id: UUID, to state: StewardState) {
        guard var result = results[id] else { return }
        result.state = state
        if case .dispatched(let name) = state {
            result.toolName = name
        }
        if case .executing(let name) = state {
            result.toolName = name
        }
        results[id] = result
        histories[id, default: []].append(state)
    }

    private func finish(
        id: UUID, state: StewardState, toolName: String?,
        rawText: String?, cleanedText: String?, isError: Bool
    ) {
        let result = StewardResult(
            id: id, state: state, toolName: toolName,
            rawText: rawText, cleanedText: cleanedText, isError: isError)
        results[id] = result
        histories[id, default: []].append(state)
        requests[id] = nil
        finishedOrder.append(id)
        let pending = waiters.removeValue(forKey: id) ?? []
        for continuation in pending {
            continuation.resume(returning: result)
        }
    }

    private func completeRun(id: UUID) {
        if runningID == id {
            runningID = nil
            runningTask = nil
        }
        cancelRequested.remove(id)
        ownerInterruptRequested.remove(id)
        startNextIfIdle()
    }
}
