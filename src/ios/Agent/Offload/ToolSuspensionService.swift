import Combine
import Foundation

// MARK: - [s2-suspend-base] 通用挂起服务
//
// 对齐目标：把原来只给 offload 命令用的"挂起等点按"机制抽成通用底座——
// 挂起 → 弹窗 → 用户点按 → 任务继续/取消，支持排队、超时、本次会话放行。
// 依据：项目现有做法（OffloadPermissionManager 已验证的挂起机制）＋
// Kelivo 补课笔记的三层审批思路。现有 offload 弹窗行为保持不变，
// 只是把底座抽出来，给"高风险工具审批"和"问用户"复用。

/// 挂起被解决后，给等待中任务的决策。
enum SuspensionDecision: Sendable {
    /// 审批通过。grantSession=true 表示"本次会话不再问这类请求"。
    case approved(grantSession: Bool)
    case denied
    /// 问用户的答案（JSON 字符串）。
    case answered(String)
    case skipped
    /// 超时未点按。
    case timedOut
}

/// 一行展示用的键值对（审批弹窗里的参数行）。
struct ApprovalRow: Sendable, Hashable {
    let key: String
    let value: String
}

/// 审批类挂起的载荷。
struct ApprovalPayload: Sendable {
    let title: String
    let description: String
    let rows: [ApprovalRow]
    /// 会话放行的键（如 "mcp-tool:notion/search"）；nil 表示不给会话放行（每次都问）。
    let grantKey: String?
    /// 是否在弹窗里显示"本次会话不再询问"开关。
    let allowSessionGrant: Bool
    let approveLabel: String
    let denyLabel: String
    /// 被拒绝时回给 AI 的说明文字。
    let denyMessage: String
    /// tag 专属的上下文（如 offload 的 commandName/fullCommand），UI 映射时用。
    let context: [String: String]
}

/// 问用户类挂起的一道题。
struct AskQuestion: Codable, Sendable, Hashable {
    let id: String
    let question: String
    /// "single" 单选 / "multi" 多选。
    let type: String
    let options: [String]

    var isMulti: Bool { type.lowercased() == "multi" }
}

/// 问用户类挂起的载荷。
struct AskPayload: Codable, Sendable {
    let title: String
    let questions: [AskQuestion]
}

/// 挂起种类。
enum SuspensionKind: Sendable {
    case approval(ApprovalPayload)
    case askUser(AskPayload)
}

/// 一条挂起请求。
struct SuspendedRequest: Identifiable, Sendable {
    let id: String
    let tag: String
    let kind: SuspensionKind
    let sessionId: String?
    let createdAt: Date
    /// 秒；nil 表示一直等用户点按（问用户用）。
    let timeoutSeconds: TimeInterval?
}

/// 持久化的"没答完的问题"——App 被杀后下次打开捞回来接着答。
struct PersistedAsk: Codable, Identifiable, Sendable {
    let id: String
    let sessionId: String
    let toolCallId: String
    let toolName: String
    let payload: AskPayload
    let createdAt: Date
}

/// 通用挂起服务：同一时间只呈现一条挂起，其余 FIFO 排队；
/// 超时自动按 timedOut 解决；支持按会话放行；问用户支持持久化恢复。
@MainActor
final class ToolSuspensionService: ObservableObject {
    static let shared = ToolSuspensionService()

    /// 正在呈现的挂起（nil 表示没有）。
    @Published private(set) var current: SuspendedRequest?
    /// App 被杀后恢复出来的"没答完的问题"。
    @Published private(set) var restoredAsks: [PersistedAsk] = []

    private var queue: [SuspendedRequest] = []
    private var continuations: [String: CheckedContinuation<SuspensionDecision, Never>] = [:]
    private var timeoutTasks: [String: Task<Void, Never>] = [:]
    /// 按会话放行：[sessionId: Set<grantKey>]。
    private var sessionGrants: [String: Set<String>] = [:]

    private let asksDefaultsKey = "toolSuspension.pendingAsks"
    private let logger = AppLogger(category: "ToolSuspension")

    private init() {
        var asks = loadPersistedAsks()
        // sessionId 为空的问询找不到原会话投回去，直接清掉，不让它占住排队。
        let validAsks = asks.filter { !$0.sessionId.isEmpty }
        if validAsks.count != asks.count {
            persistAsks(validAsks)
            asks = validAsks
        }
        restoredAsks = asks
        if !asks.isEmpty {
            logger.info("Restored \(asks.count) unanswered ask(s) from previous run")
            // [s2-askuser] 恢复的问题只进排队、不占 current（占住 current 会堵住
            // 后面其他会话的审批/问询）。呈现时按会话过滤（见 askRequestForSession），
            // 答案投回原会话（见 respond 的 restored 分支）。
            for ask in asks {
                queue.append(SuspendedRequest(
                    id: ask.id,
                    tag: "ask-user-restored",
                    kind: .askUser(ask.payload),
                    sessionId: ask.sessionId,
                    createdAt: ask.createdAt,
                    timeoutSeconds: nil
                ))
            }
        }
    }

    // MARK: - 挂起

    /// 挂起一条请求直到用户点按（或超时）。同一时间只呈现一条，其余排队。
    func suspend(
        tag: String,
        kind: SuspensionKind,
        sessionId: String?,
        timeoutSeconds: TimeInterval?
    ) async -> SuspensionDecision {
        let request = SuspendedRequest(
            id: UUID().uuidString,
            tag: tag,
            kind: kind,
            sessionId: sessionId,
            createdAt: Date(),
            timeoutSeconds: timeoutSeconds
        )
        return await wait(for: request)
    }

    /// 审批类挂起的便捷入口。
    func suspendApproval(
        tag: String = "tool-approval",
        title: String,
        description: String = "",
        rows: [ApprovalRow] = [],
        grantKey: String?,
        allowSessionGrant: Bool,
        approveLabel: String = "允许",
        denyLabel: String = "拒绝",
        denyMessage: String,
        context: [String: String] = [:],
        sessionId: String?,
        timeoutSeconds: TimeInterval? = 30
    ) async -> SuspensionDecision {
        let payload = ApprovalPayload(
            title: title,
            description: description,
            rows: rows,
            grantKey: grantKey,
            allowSessionGrant: allowSessionGrant,
            approveLabel: approveLabel,
            denyLabel: denyLabel,
            denyMessage: denyMessage,
            context: context
        )
        return await suspend(tag: tag, kind: .approval(payload), sessionId: sessionId, timeoutSeconds: timeoutSeconds)
    }

    /// 问用户类挂起：先持久化（App 被杀可恢复），再挂起等点按；无超时。
    func suspendAsk(payload: AskPayload, toolName: String, toolCallId: String, sessionId: String?) async -> SuspensionDecision {
        let ask = PersistedAsk(
            id: UUID().uuidString,
            sessionId: sessionId ?? "",
            toolCallId: toolCallId,
            toolName: toolName,
            payload: payload,
            createdAt: Date()
        )
        savePersistedAsk(ask)
        let request = SuspendedRequest(
            id: ask.id,
            tag: "ask-user",
            kind: .askUser(payload),
            sessionId: sessionId,
            createdAt: ask.createdAt,
            timeoutSeconds: nil
        )
        return await wait(for: request)
    }

    /// 入队并等用户点按。调用方 Task 被取消时（如用户点了停止），
    /// 按跳过解决，避免 checked continuation 永远泄漏。
    private func wait(for request: SuspendedRequest) async -> SuspensionDecision {
        // 任务进 wait 之前已经取消：直接按跳过回（不入队、不弹窗）。
        // 注意：此时 suspendAsk 已持久化了这条问询——它会变成"没答完的问题"，
        // 下次打开 App 时用户仍可回答并让 AI 从断点继续，这是符合预期的。
        if Task.isCancelled { return .skipped }
        return await withTaskCancellationHandler(operation: {
            await withCheckedContinuation { continuation in
                continuations[request.id] = continuation
                if current == nil {
                    activate(request)
                } else {
                    queue.append(request)
                }
            }
        }, onCancel: {
            // onCancel 是 @Sendable：不抓 self，只带走 id，用 shared 回。
            let requestID = request.id
            Task { @MainActor in
                ToolSuspensionService.shared.respond(id: requestID, decision: .skipped)
            }
        })
    }

    // MARK: - 解决

    /// 用户点按后调用。
    func respond(id: String, decision: SuspensionDecision) {
        // [s2-askuser] 恢复的问询没有等待中的 Task：答案/跳过直接投回原会话，
        // 不走 continuation。投完再 finish 清掉呈现、顶起排队的下一条。
        if let request = requestFor(id: id), request.tag == "ask-user-restored",
           let ask = restoredAsks.first(where: { $0.id == id }) {
            switch decision {
            case .answered(let json):
                answerRestoredAsk(ask, answerJSON: json)
            case .skipped:
                skipRestoredAsk(ask)
            default:
                removePersistedAsk(id: id)
            }
            finish(id: id, decision: decision)
            return
        }
        // 问用户一旦有了答案/跳过，持久化记录就不再需要。
        if case .askUser = requestFor(id: id)?.kind {
            switch decision {
            case .answered, .skipped:
                removePersistedAsk(id: id)
            default:
                break
            }
        }
        finish(id: id, decision: decision)
    }

    // MARK: - 按会话呈现问询

    /// 当前会话可呈现的问询请求。恢复的问题只在它自己的会话里呈现
    /// （避免答案投错会话）；实时问询 sessionId 为空或一致时呈现。
    /// 正在呈现非问询的挂起（审批等）时返回 nil——一次只呈现一条，
    /// 问询等它解决；跨会话的问询不抢占，用户切到那个会话时再呈现。
    func askRequestForSession(_ sessionId: String?) -> SuspendedRequest? {
        if let cur = current, cur.tag != "ask-user", cur.tag != "ask-user-restored" {
            return nil
        }
        var candidates: [SuspendedRequest] = []
        if let cur = current { candidates.append(cur) }
        candidates.append(contentsOf: queue)
        for req in candidates {
            guard req.tag == "ask-user" || req.tag == "ask-user-restored" else { continue }
            if req.tag == "ask-user-restored" {
                // sessionId 为空的恢复问询投不回去（answerRestoredAsk 会清掉），不呈现。
                if req.sessionId != nil, req.sessionId == sessionId { return req }
            } else if req.sessionId == nil || req.sessionId == sessionId {
                return req
            }
        }
        return nil
    }

    // MARK: - 会话放行

    func hasSessionGrant(_ grantKey: String, sessionId: String?) -> Bool {
        guard let sessionId, !sessionId.isEmpty else { return false }
        return sessionGrants[sessionId]?.contains(grantKey) ?? false
    }

    func grantSession(_ grantKey: String, sessionId: String?) {
        guard let sessionId, !sessionId.isEmpty else { return }
        sessionGrants[sessionId, default: []].insert(grantKey)
    }

    func clearSessionGrants(sessionId: String) {
        sessionGrants[sessionId] = nil
    }

    func clearAllSessionGrants() {
        sessionGrants.removeAll()
    }

    // MARK: - 恢复的问询

    /// 回答一条恢复出来的问题：把答案投回原会话继续跑。
    /// 返回 true 表示答案已投递；会话正忙时返回 false，持久化保留、
    /// 下次启动重新呈现（往跑着的 turn 里硬塞 tool_result 会把配对搞乱）。
    @discardableResult
    func answerRestoredAsk(_ ask: PersistedAsk, answerJSON: String, summary: String? = nil) -> Bool {
        // sessionId 为空说明当初问的时候会话还没落盘，找不到原会话——
        // 清掉持久化，不让它每次启动都冒出来。
        guard !ask.sessionId.isEmpty else {
            logger.warning("answerRestoredAsk: empty sessionId, dropping ask \(ask.id.prefix(8))")
            removePersistedAsk(id: ask.id)
            return true
        }
        let vm = ViewModelCache.shared.getOrCreate(for: ask.sessionId).0
        guard !vm.isProcessing else {
            logger.info("answerRestoredAsk: session busy, keep persisted ask for later")
            return false
        }
        removePersistedAsk(id: ask.id)
        vm.continueAfterRestoredAsk(
            toolCallId: ask.toolCallId,
            toolName: ask.toolName,
            answerJSON: answerJSON,
            summary: summary ?? "之前没答完的问题已回答（\(ask.payload.questions.count) 道），继续之前的操作。"
        )
        return true
    }

    /// 跳过一条恢复出来的问题：每道题都记为 null，让 AI 自己拿主意继续。
    func skipRestoredAsk(_ ask: PersistedAsk) {
        // uniquingKeysWith：旧版本存下的问题 id 可能重复，uniqueKeysWithValues 会 fatalError。
        let nulls = Dictionary(ask.payload.questions.map { ($0.id, NSNull()) }, uniquingKeysWith: { first, _ in first })
        let data = try? JSONSerialization.data(withJSONObject: nulls, options: [])
        let json = data.flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        answerRestoredAsk(
            ask,
            answerJSON: json,
            summary: "之前没答完的问题已跳过（\(ask.payload.questions.count) 道），按你的判断继续之前的操作。"
        )
    }

    // MARK: - 查询（供调用方去重/映射）

    /// 在当前呈现＋排队的请求里找符合条件的。
    func firstPending(tag: String, where predicate: (SuspendedRequest) -> Bool) -> SuspendedRequest? {
        if let c = current, c.tag == tag, predicate(c) { return c }
        return queue.first { $0.tag == tag && predicate($0) }
    }

    // MARK: - 内部

    private func requestFor(id: String) -> SuspendedRequest? {
        if current?.id == id { return current }
        return queue.first { $0.id == id }
    }

    private func activate(_ request: SuspendedRequest) {
        current = request
        // 超时从呈现那一刻开始算——排队时用户还没看见，不能算超时。
        if let timeout = request.timeoutSeconds {
            timeoutTasks[request.id] = Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                guard !Task.isCancelled else { return }
                await self?.handleTimeout(id: request.id)
            }
        }
    }

    private func handleTimeout(id: String) {
        guard current?.id == id else { return }
        logger.info("Suspension timed out: \(id)")
        finish(id: id, decision: .timedOut)
    }

    private func finish(id: String, decision: SuspensionDecision) {
        timeoutTasks[id]?.cancel()
        timeoutTasks[id] = nil

        let request = requestFor(id: id)
        let wasCurrent = current?.id == id
        if wasCurrent {
            current = nil
        } else {
            queue.removeAll { $0.id == id }
        }
        if let cont = continuations.removeValue(forKey: id) {
            cont.resume(returning: decision)
        }

        // 会话放行：只有明确点了"本次会话不再询问"才记。
        // 注意：approved 的关联值与放行方法同名，这里改名避免遮住方法。
        if case .approved(let grantSessionFlag) = decision, grantSessionFlag,
           case .approval(let payload) = request?.kind,
           let grantKey = payload.grantKey {
            grantSession(grantKey, sessionId: request?.sessionId)
        }

        // 只有正在呈现的那条被解决，才顶起排队的下一条。
        // 恢复的问询不参与顶起——它们只进排队、按会话呈现（askRequestForSession）；
        // 一旦占住 current，用户不打开原会话就永久堵死后面其他会话的审批/问询。
        if wasCurrent, let next = queue.first(where: { $0.tag != "ask-user-restored" }) {
            queue.removeAll { $0.id == next.id }
            activate(next)
        }
    }

    // MARK: - 问询持久化

    private func loadPersistedAsks() -> [PersistedAsk] {
        guard let data = UserDefaults.standard.data(forKey: asksDefaultsKey),
              let asks = try? JSONDecoder().decode([PersistedAsk].self, from: data)
        else { return [] }
        return asks
    }

    private func persistAsks(_ asks: [PersistedAsk]) {
        if let data = try? JSONEncoder().encode(asks) {
            UserDefaults.standard.set(data, forKey: asksDefaultsKey)
        }
        restoredAsks = asks
    }

    private func savePersistedAsk(_ ask: PersistedAsk) {
        var asks = loadPersistedAsks()
        asks.removeAll { $0.id == ask.id }
        asks.append(ask)
        persistAsks(asks)
    }

    private func removePersistedAsk(id: String) {
        var asks = loadPersistedAsks()
        guard asks.contains(where: { $0.id == id }) else { return }
        asks.removeAll { $0.id == id }
        persistAsks(asks)
    }
}
