import Combine
import Foundation

// MARK: - [s2-approve] 高风险工具审批关卡
//
// 对齐目标：高风险工具先问用户再执行——
//   1. MCP 工具逐个可设"需批准"，没登记过的默认要问；
//   2. 建日历/建提醒/完成提醒等写动作永远先问（不设开关）；
//   3. 工作区命令（shell_execute）给个总开关，默认关，本次会话可一键全放行。
// 依据：她定的"危险动作必须经过她"（功能取舍她的）＋ Kelivo 逐工具审批做法。
// 推断（待她拍板）：shell 总开关默认关。
//
// 挂在 shell_execute 的命令解析处——MCP 工具实际走的也是 shell_execute
//（`minis-mcp-cli call <server> <tool>`），所以逐工具审批落在这里。

/// 关卡结果。
enum ToolGateOutcome {
    case proceed
    /// 被拦下；associated 是回给 AI 的说明文字（AI 会转述/换路）。
    case blocked(String)
}

/// shell_execute 的审批关卡。
/// @MainActor：体内同步读写 MCPToolApprovalStore / OffloadPermissionManager /
/// ShellApprovalSettings / ToolSuspensionService 全是 @MainActor 状态；挂在并发跑的
/// executeSingleToolUse 里，不隔离就是后台线程和主线程同时读写 Dictionary，
/// 会直接崩。调用方（ConcurrentTools）本来就在 @MainActor 上，无破坏。
@MainActor
enum ToolApprovalGate {
    /// 检查一条 shell 命令是否需要先问用户。返回 .proceed 才能继续执行。
    static func checkShellCommand(_ command: String, sessionId: String?) async -> ToolGateOutcome {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .proceed }

        let suspension = ToolSuspensionService.shared

        // 1. MCP 工具调用：`minis-mcp-cli call <server> <tool> [--input json]`。
        //    逐工具审批，未登记过的默认要问。
        //    MCP 调用只走这一道审批（不再过下面的 shell 总开关，避免问两遍）。
        if let (server, tool) = parseMCPCall(trimmed) {
            if MCPToolApprovalStore.shared.needsApproval(serverId: server, tool: tool) {
                let grantKey = "mcp-tool:\(server)/\(tool)"
                // 本次会话已经点过"不再询问"：直接放行，不再弹窗。
                if suspension.hasSessionGrant(grantKey, sessionId: sessionId) {
                    return .proceed
                }
                let denyMessage = "用户拒绝了这次 MCP 工具调用（\(server)/\(tool)），没有执行。"
                let decision = await suspension.suspendApproval(
                    title: "\(server) / \(tool)",
                    description: "AI 想调用 MCP 工具，这会用到第三方服务。",
                    rows: [
                        ApprovalRow(key: "服务器", value: server),
                        ApprovalRow(key: "工具", value: tool),
                        ApprovalRow(key: "命令", value: String(trimmed.prefix(300))),
                    ],
                    grantKey: grantKey,
                    allowSessionGrant: true,
                    denyMessage: denyMessage,
                    sessionId: sessionId,
                    timeoutSeconds: 30
                )
                return outcome(of: decision, denyMessage: denyMessage)
            }
            return .proceed
        }

        // 2. 日历/提醒的写动作：永远先问，没有开关，不给"本次会话放行"。
        //    读（list/reminders/freebusy/calendars）不受影响。
        if let offloadCmd = OffloadPermissionManager.extractOffloadCommand(from: trimmed),
           offloadCmd == "apple-calendar" || offloadCmd == "apple-reminders" {
            let (isWrite, subcommand) = writeSubcommand(command: offloadCmd, fullCommand: trimmed)
            if isWrite {
                // 用户在"设置＞权限"里关掉（Not Allowed）的，直接拒绝，不弹窗。
                if OffloadPermissionManager.shared.permissionLevel(for: offloadCmd) == .notAllowed {
                    return .blocked("Permission denied: the user has disabled '\(offloadCmd)'. To enable it, go to Settings > Permissions or tap: [Open Permissions](minis-clone://settings/permissions)")
                }
                let actionDesc = writeActionDescription(command: offloadCmd, subcommand: subcommand)
                let denyMessage = "用户拒绝了这次写入（\(offloadCmd) \(subcommand)），日历/提醒没有被改动。"
                let decision = await suspension.suspendApproval(
                    title: "\(offloadCmd) · \(subcommand)",
                    description: "AI 想\(actionDesc)，会改动你的\(offloadCmd == "apple-calendar" ? "日历" : "提醒事项")。",
                    rows: [ApprovalRow(key: "命令", value: String(trimmed.prefix(300)))],
                    grantKey: nil, // 写动作每次都问
                    allowSessionGrant: false,
                    denyMessage: denyMessage,
                    sessionId: sessionId,
                    timeoutSeconds: 30
                )
                return outcome(of: decision, denyMessage: denyMessage)
            }
            // offload 命令（读/写）走各自的权限等级体系，不再过 shell 总开关，避免问两遍。
            return .proceed
        }
        // 其他 offload 命令（健康、照片、位置等）同样走自己的权限等级，不重复问。
        if OffloadPermissionManager.extractOffloadCommand(from: trimmed) != nil {
            return .proceed
        }

        // 3. 工作区命令总开关：打开后，每条 shell 命令执行前都问一次，
        //    可点"本次会话不再询问"一键放行。默认关。
        if ShellApprovalSettings.shared.needsApproval {
            let grantKey = "shell"
            if suspension.hasSessionGrant(grantKey, sessionId: sessionId) {
                return .proceed
            }
            let denyMessage = "用户拒绝了这条命令，没有执行。"
            let decision = await suspension.suspendApproval(
                title: "执行命令",
                description: "AI 想在工作区执行一条命令。",
                rows: [ApprovalRow(key: "命令", value: String(trimmed.prefix(500)))],
                grantKey: grantKey,
                allowSessionGrant: true,
                denyMessage: denyMessage,
                sessionId: sessionId,
                timeoutSeconds: 30
            )
            return outcome(of: decision, denyMessage: denyMessage)
        }

        return .proceed
    }

    // MARK: - 解析

    /// 解析 `minis-mcp-cli call <server> <tool> [--input json]`。
    /// 只看第一条命令（与系统提示词教模型的用法一致）。
    static func parseMCPCall(_ command: String) -> (server: String, tool: String)? {
        let tokens = command.split(separator: " ").map(String.init)
        guard tokens.count >= 4 else { return nil }
        let first = (tokens[0] as NSString).lastPathComponent
        guard first == "minis-mcp-cli", tokens[1] == "call" else { return nil }
        let server = tokens[2], tool = tokens[3]
        guard !server.isEmpty, !tool.isEmpty, !tool.hasPrefix("-") else { return nil }
        return (server, tool)
    }

    /// 日历/提醒子命令是不是写动作。依据 NativeOffloads/CalendarOffload.m
    /// 与 RemindersOffload.m 的子命令分发（源码为准）。
    static func writeSubcommand(command: String, fullCommand: String) -> (isWrite: Bool, subcommand: String) {
        let tokens = fullCommand.split(separator: " ").map(String.init)
        guard tokens.count >= 2 else { return (false, "") }
        let sub = tokens[1]
        let writes: Set<String>
        switch command {
        case "apple-calendar":
            // 读：list / reminders / freebusy / calendars
            writes = ["create", "update", "delete", "remind", "update-reminder", "complete-reminder", "delete-reminder"]
        case "apple-reminders":
            // 读：list
            writes = ["create", "update", "complete", "delete"]
        default:
            return (false, "")
        }
        return (writes.contains(sub.lowercased()), sub)
    }

    private static func writeActionDescription(command: String, subcommand: String) -> String {
        switch (command, subcommand.lowercased()) {
        case ("apple-calendar", "create"): return "创建一个日历事件"
        case ("apple-calendar", "update"): return "修改一个日历事件"
        case ("apple-calendar", "delete"): return "删除一个日历事件"
        case ("apple-calendar", "remind"): return "创建一个提醒"
        case ("apple-calendar", "update-reminder"): return "修改一个提醒"
        case ("apple-calendar", "complete-reminder"): return "完成一个提醒"
        case ("apple-calendar", "delete-reminder"): return "删除一个提醒"
        case ("apple-reminders", "create"): return "创建一个提醒事项"
        case ("apple-reminders", "update"): return "修改一个提醒事项"
        case ("apple-reminders", "complete"): return "完成一个提醒事项"
        case ("apple-reminders", "delete"): return "删除一个提醒事项"
        default: return "写入（\(subcommand)）"
        }
    }

    private static func outcome(of decision: SuspensionDecision, denyMessage: String) -> ToolGateOutcome {
        switch decision {
        case .approved:
            return .proceed
        case .denied, .timedOut:
            return .blocked(denyMessage)
        default:
            // 问用户/跳过不会出现在审批挂起里，防御性地按拒绝处理。
            return .blocked(denyMessage)
        }
    }
}

// MARK: - MCP 逐工具审批

/// 读/写 MCPServerConfig.toolApprovals。未登记过的工具默认需要批准。
@MainActor
final class MCPToolApprovalStore: ObservableObject {
    static let shared = MCPToolApprovalStore()

    /// 本地 UI 刷新用（toggle 写后 bump）。
    @Published private(set) var revision = 0

    private init() {}

    func needsApproval(serverId: String, tool: String) -> Bool {
        let config = MCPStore.shared.servers.first { $0.id == serverId }
        return config?.toolApprovals?[tool] ?? true
    }

    func setNeedsApproval(_ needsApproval: Bool, serverId: String, tool: String) {
        MCPStore.shared.setToolApproval(serverId: serverId, tool: tool, needsApproval: needsApproval)
        revision += 1
    }
}

// MARK: - 工作区命令总开关

/// shell_execute 审批总开关。默认关；打开后每条命令执行前都问。
@MainActor
final class ShellApprovalSettings: ObservableObject {
    static let shared = ShellApprovalSettings()

    private let defaultsKey = "toolApproval.shellNeedsApproval"

    @Published var needsApproval: Bool {
        didSet { UserDefaults.standard.set(needsApproval, forKey: defaultsKey) }
    }

    private init() {
        // UserDefaults.bool(forKey:) 缺省 false → 默认关。
        needsApproval = UserDefaults.standard.bool(forKey: defaultsKey)
    }
}
